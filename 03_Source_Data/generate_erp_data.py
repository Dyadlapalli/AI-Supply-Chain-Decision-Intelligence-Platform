"""
Generate ERP transaction extracts for the Caterpillar-dealer supply chain platform.

Reads the golden master data (run generate_master_data.py first) and simulates
day-by-day parts operations at every branch from 2023-01-01 to 2026-09-30:

    customer demand -> sales orders -> stock issues / backorders / lost sales
    reorder point breached -> purchase orders (or branch-to-branch transfers)
    supplier ships (late, partial, damaged...) -> goods receipts -> backorders filled

Because every file comes from the same simulation, they reconcile with each other.

Outputs (under 03_Source_Data/erp_data/):
    golden/  - clean extracts                                    (git-ignored, ~50 MB)
    raw/     - the same extracts with realistic ERP defects injected (git-ignored, ~50 MB)
    sample/  - first 1,000 rows of each extract, committed for browsing
    dq_issue_log.csv - answer key of every injected defect

Usage:
    python generate_erp_data.py               # ~75k sales lines
    python generate_erp_data.py --scale 0.3   # smaller
"""

import argparse
import math
from collections import defaultdict, deque
from datetime import date, datetime, timedelta
from pathlib import Path

import numpy as np
import pandas as pd

HERE = Path(__file__).parent
MASTER_DIR = HERE / "master_data" / "golden"
OUT_DIR = HERE / "erp_data"
START, END = date(2023, 1, 1), date(2026, 9, 30)
SALES_LINES_PER_DAY = 70  # average demand events per day across the network at scale 1.0
SAMPLE_ROWS = 1000

# Relative demand velocity and stocking likelihood by part category
VELOCITY = {"Filters": 1.0, "Fluids": 1.2, "Hardware": 0.9, "Ground Engaging Tools": 0.55,
            "Undercarriage": 0.22, "Hydraulics": 0.18, "Engine": 0.14, "Electrical": 0.18,
            "Cooling": 0.10, "Power Train": 0.05, "Cab": 0.06, "Tires": 0.07}
QTY_MEAN = {"Filters": 3.0, "Hardware": 8.0, "Ground Engaging Tools": 6.0, "Undercarriage": 2.0}
MARKUP = {"Filters": 1.45, "Fluids": 1.35, "Hardware": 1.6, "Ground Engaging Tools": 1.4}
BRANCH_SIZE = {"Full Service": 1.0, "Parts & Service": 0.8, "Rental Store": 0.45}
Z_SCORE = {"High": 1.65, "Medium": 1.0, "Low": 0.5}
PRICE_LEVEL = {2023: 0.88, 2024: 0.93, 2025: 0.965, 2026: 1.0}   # annual Cat price increases
MARKET_LEVEL = {2023: 1.0, 2024: 0.96, 2025: 1.0, 2026: 1.04}    # construction market cycle

CONSTRUCTION = [0.70, 0.75, 0.95, 1.10, 1.20, 1.20, 1.12, 1.15, 1.10, 1.02, 0.85, 0.70]
SEASONALITY = {
    "Excavation": CONSTRUCTION, "Earthmoving": CONSTRUCTION, "Material Handling": CONSTRUCTION,
    "Road Construction": [0.45, 0.5, 0.85, 1.15, 1.35, 1.4, 1.35, 1.35, 1.25, 1.1, 0.7, 0.45],
    "Work Tools & Attachments": CONSTRUCTION,
    "Forestry": [1.1, 1.1, 0.85, 0.85, 0.95, 1.0, 1.0, 1.0, 1.0, 1.05, 1.05, 1.05],
    "Mining": [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.95, 1.0, 1.0, 1.0, 1.0, 0.9],
    "Underground Mining": [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.95, 1.0, 1.0, 1.0, 1.0, 0.9],
    "Power Systems": [1.0] * 12,
    "Marine & Oil and Gas": [0.9, 0.9, 1.05, 1.15, 1.15, 1.1, 1.0, 1.0, 1.0, 1.0, 0.9, 0.85],
}
WEEKDAY = [1.0, 1.0, 1.0, 1.0, 0.95, 0.3, 0.04]
CHANNELS = (["Counter", "Service Work Order", "Phone", "Online"], [0.38, 0.27, 0.15, 0.20])

CUSTOMER_PREFIX = ["Blue Ridge", "Tidewater", "Commonwealth", "Shenandoah", "Appalachian", "James River",
                   "Old Dominion", "Piedmont", "Allegheny", "Chesapeake", "Potomac", "New River",
                   "Clinch Valley", "Tri-State", "Mountaineer", "Rappahannock", "Southside", "Cardinal",
                   "Patriot", "Eastern Shore", "Valley", "Ridgeline", "Coalfield", "Pocahontas"]
CUSTOMER_SUFFIX = {"construction": ["Excavating", "Grading & Paving", "Site Works", "Construction",
                                    "Contracting", "Utilities", "Earthworks", "Demolition", "Land Clearing"],
                   "mining": ["Coal Company", "Mining LLC", "Aggregates", "Stone & Quarry", "Resources"],
                   "power": ["Power Generation", "Hospital System", "Data Centers", "Marine Services",
                             "Municipal Utilities"]}


def load_master():
    m = {n: pd.read_csv(MASTER_DIR / f"{n}.csv") for n in
         ["branch_master", "part_master", "supplier_master", "product_master",
          "product_family_master", "equipment_master"]}
    if any(df.empty for df in m.values()):
        raise SystemExit("Golden master data missing - run generate_master_data.py first")
    return m


def calendar_factors(days):
    """Weekday, holiday and market-cycle multipliers for each simulated day."""
    def nth_weekday(y, month, weekday, n):
        d = date(y, month, 1)
        d += timedelta(days=(weekday - d.weekday()) % 7)
        return d + timedelta(weeks=n - 1) if n > 0 else None

    holidays = set()
    for y in range(START.year, END.year + 1):
        holidays |= {date(y, 1, 1), date(y, 7, 4), date(y, 12, 25), date(y, 12, 24),
                     nth_weekday(y, 11, 3, 4), nth_weekday(y, 9, 0, 1)}
        last_may = date(y, 5, 31)
        holidays.add(last_may - timedelta(days=last_may.weekday()))
    return np.array([WEEKDAY[d.weekday()] * MARKET_LEVEL[d.year] * (0.05 if d in holidays else 1.0)
                     for d in days])


def build_customers(branches, rng):
    rows, n = [], 1
    for _, b in branches.iterrows():
        mix = {"construction": 22, "mining": 8 if b.region == "Southwest" else 1,
               "power": 4 if b.region in ("East", "North") else 2}
        for kind, count in mix.items():
            for _ in range(int(count * BRANCH_SIZE[b.branch_type]) + 1):
                name = f"{rng.choice(CUSTOMER_PREFIX)} {rng.choice(CUSTOMER_SUFFIX[kind])}"
                name += rng.choice(["", " LLC", " Inc.", ", Inc.", " Co."], p=[0.3, 0.3, 0.2, 0.1, 0.1])
                rows.append((f"C{n:05d}", name, b.branch_id, kind))
                n += 1
    # A few public-sector accounts per state
    for state, counties in {"VA": ["Henrico County", "Chesterfield County", "City of Virginia Beach",
                                   "Roanoke County", "Washington County"],
                            "WV": ["Mercer County", "Raleigh County"],
                            "MD": ["Washington County MD", "Wicomico County"]}.items():
        for c in counties:
            home = branches[branches.state == state].branch_id.iloc[0]
            rows.append((f"C{n:05d}", f"{c} Public Works", home, "construction"))
            n += 1
    return pd.DataFrame(rows, columns=["customer_id", "customer_name", "home_branch_id", "segment"])


# ---------------------------------------------------------------------------
# Simulation
# ---------------------------------------------------------------------------

def simulate(master, rng, scale):
    branches = master["branch_master"]
    parts = master["part_master"].set_index("part_id")
    suppliers = master["supplier_master"].set_index("supplier_id")
    fam_name = master["product_family_master"].set_index("product_family_id").product_family_name
    prod_family = master["product_master"].set_index("product_id").product_family_id.map(fam_name)
    parts["family"] = parts.primary_product_id.map(prod_family)

    # --- What each branch stocks --------------------------------------------------------------
    combos = []
    for _, b in branches.iterrows():
        size = BRANCH_SIZE[b.branch_type]
        affinity = np.ones(len(parts))
        fam = parts.family.values
        if b.region == "Southwest":
            affinity[np.isin(fam, ["Mining", "Underground Mining"])] = 3.0
            affinity[fam == "Forestry"] = 1.8
        else:
            affinity[np.isin(fam, ["Mining", "Underground Mining"])] = 0.15
        affinity[fam == "Marine & Oil and Gas"] = 2.0 if b.region == "East" else 0.3
        weight = parts.part_category.map(VELOCITY).values * affinity
        n_stock = int(220 * size)
        chosen = rng.choice(len(parts), size=min(n_stock, len(parts)), replace=False, p=weight / weight.sum())
        chosen = set(chosen) | set(np.flatnonzero(parts.part_category.values == "Fluids"))
        for pi in chosen:
            combos.append((b.branch_id, b.region, size, parts.index[pi], affinity[pi]))
    cb = pd.DataFrame(combos, columns=["branch_id", "region", "size", "part_id", "affinity"])
    cb = cb.join(parts[["part_number", "part_description", "part_category", "criticality", "unit_cost_usd",
                        "unit_of_measure", "primary_supplier_id", "primary_product_id", "family"]], on="part_id")
    C = len(cb)

    # --- Demand rates, normalized so network volume hits the target -----------------------------
    rate = cb.part_category.map(VELOCITY).values * cb["size"].values * cb.affinity.values
    rate *= rng.lognormal(0, 0.8, C)
    rate *= SALES_LINES_PER_DAY * scale / rate.sum() / 0.8  # 0.8 ~ avg calendar factor
    qmean = cb.part_category.map(QTY_MEAN).fillna(1.25).to_numpy(dtype=float, copy=True)
    is_fluid = (cb.part_category == "Fluids").values
    qmean[is_fluid] = 14.0
    eq2 = np.where(is_fluid, 14.0 ** 2 + 230, (qmean - 1) + qmean ** 2)

    # --- Stocking policy (planner's estimate of demand is imperfect) -----------------------------
    sup = suppliers.loc[cb.primary_supplier_id]
    lt_plan = sup.lead_time_days.values.astype(float)
    otd = sup.on_time_delivery_pct.values / 100
    is_oem = sup.supplier_type.str.startswith("OEM").values
    mu_est = rate * qmean * 0.8 * rng.lognormal(0, 0.35, C)
    sigma = np.sqrt(rate * 0.8 * eq2)
    z = cb.criticality.map(Z_SCORE).values
    rop = np.ceil(mu_est * (lt_plan + 1) + z * sigma * np.sqrt(lt_plan + 1)).astype(int)
    rop = np.maximum(rop, np.ceil(qmean * np.where(z > 1, 1.5, 1.0))).astype(int)  # stocked = at least one typical sale
    cost = cb.unit_cost_usd.values
    cover = np.where(cost < 200, 30, np.where(cost < 2000, 21, 10))
    order_qty = np.maximum(1, np.ceil(mu_est * cover)).astype(int)
    order_qty[is_fluid] = np.maximum(55, (order_qty[is_fluid] // 55 + 1) * 55)
    on_hand = (rop + rng.integers(0, order_qty + 1)).astype(int)
    on_order = np.zeros(C, dtype=int)
    backlog_qty = np.zeros(C, dtype=int)
    backlog = defaultdict(deque)  # combo -> deque[[demand_row, remaining]]

    # Sibling combos (same part, other branches) for transfers
    siblings = cb.groupby("part_id").indices
    region = cb.region.values

    # --- Calendar ---------------------------------------------------------------------------------
    days = [START + timedelta(days=i) for i in range((END - START).days + 1)]
    cal = calendar_factors(days)
    fam_idx = {f: i for i, f in enumerate(SEASONALITY)}
    combo_fam = cb.family.map(fam_idx).values
    season = np.array([[SEASONALITY[f][d.month - 1] for f in SEASONALITY] for d in days])
    hurricane = ((cb.family.isin(["Power Systems"])) & (cb.region == "East")).values
    undercarriage = (cb.part_category == "Undercarriage").values

    customers = build_customers(branches, rng)
    cust_by_branch = customers.groupby("home_branch_id").customer_id.apply(np.array).to_dict()
    cust_name = customers.set_index("customer_id").customer_name.to_dict()
    eq = master["equipment_master"]
    serial_by_bp = eq.groupby(["home_branch_id", "product_id"]).serial_number.apply(list).to_dict()
    serial_by_b = eq.groupby("home_branch_id").serial_number.apply(list).to_dict()

    # --- Output buffers -----------------------------------------------------------------------------
    sales, demand, pos, grs, inv = [], [], [], [], []
    arrivals = defaultdict(list)    # day index -> [(combo, qty, po_ref | transfer_ref, kind)]
    returns = defaultdict(list)     # day index -> [(combo, qty, so_ref)]
    ctr = defaultdict(int)

    def next_id(kind):
        ctr[kind] += 1
        return ctr[kind]

    def stamp(d, lo=7, hi=18):
        return datetime(d.year, d.month, d.day, int(rng.integers(lo, hi)), int(rng.integers(0, 60)),
                        int(rng.integers(0, 60))).strftime("%Y-%m-%d %H:%M:%S")

    clock = {}

    def posting_time(d):
        sec = clock.get(d, 6 * 3600) + int(rng.integers(1, 20))
        clock[d] = sec
        return (datetime(d.year, d.month, d.day) + timedelta(seconds=min(sec, 86399))).strftime("%Y-%m-%d %H:%M:%S")

    def post(d, c, ttype, qty, ref_type, ref_id):
        inv.append([f"IT{next_id('it'):09d}", posting_time(d), cb.branch_id.iat[c], cb.part_id.iat[c],
                    cb.part_number.iat[c], ttype, int(qty), cb.unit_of_measure.iat[c],
                    ref_type, ref_id, int(on_hand[c]), round(cost[c] * PRICE_LEVEL[d.year], 2)])

    def business_day(i):
        while i < len(days) and days[i].weekday() >= 5:
            i += 1
        return i

    for c in range(C):
        post(START, c, "Opening Balance", on_hand[c], "MIGRATION", "OB-2023")

    for di, d in enumerate(days):
        # 1. Supplier receipts and inbound transfers
        for c, qty, ref, kind in arrivals.pop(di, []):
            if kind == "PO":
                po_row, po_line_qty = ref
                rejected = int(qty > 1 and rng.random() < 0.012)
                accepted = qty - rejected
                gr_no = f"50{next_id('gr'):08d}"
                on_hand[c] += accepted
                on_order[c] -= qty
                po = pos[po_row]
                grs.append([gr_no, 1, d.isoformat(), po[0], po[1], cb.branch_id.iat[c], po[4],
                            cb.part_id.iat[c], cb.part_number.iat[c], qty, accepted, rejected,
                            po[9], "Damaged in transit" if rejected else ""])
                po[13] += qty
                po[14] = d.isoformat()
                post(d, c, "Goods Receipt", accepted, "GR", gr_no)
            else:
                on_hand[c] += qty
                on_order[c] -= qty
                post(d, c, "Transfer In", qty, "TRANSFER", ref)
            # Fill backorders FIFO from new stock
            while backlog[c] and on_hand[c] > 0:
                entry = backlog[c][0]
                fill = min(entry[1], on_hand[c])
                on_hand[c] -= fill
                backlog_qty[c] -= fill
                entry[1] -= fill
                drow = demand[entry[0]]
                drow[10] += fill
                drow[11] = d.isoformat()
                post(d, c, "Goods Issue - Backorder", -fill, "SO", f"{drow[1]}-{drow[2]}")
                if entry[1] == 0:
                    backlog[c].popleft()

        for c, qty, so_ref in returns.pop(di, []):
            on_hand[c] += qty
            post(d, c, "Customer Return", qty, "SO", so_ref)

        # 2. Customer demand
        lam = rate * season[di, combo_fam] * cal[di]
        if d.month in (8, 9, 10):
            lam = lam * np.where(hurricane, 1.8, 1.0)
        events = np.flatnonzero(rng.poisson(lam))
        rng.shuffle(events)
        by_branch = defaultdict(list)
        for c in events:
            by_branch[cb.branch_id.iat[c]].append(c)

        for b_id, lines in by_branch.items():
            k = 0
            while k < len(lines):
                n_lines = min(int(rng.geometric(0.5)), 6, len(lines) - k)
                so = f"SO{next_id('so'):08d}"
                cust = rng.choice(cust_by_branch[b_id])
                channel = rng.choice(CHANNELS[0], p=CHANNELS[1])
                req = d if channel == "Counter" else d + timedelta(days=int(rng.integers(1, 6)))
                order_ts = stamp(d, 7, 19)
                for ln, c in enumerate(lines[k:k + n_lines], start=1):
                    if is_fluid[c]:
                        qty = int(rng.choice([5, 5, 5, 10, 15, 55]))
                    else:
                        qty = 1 + int(rng.poisson(qmean[c] - 1))
                    price = round(cost[c] * PRICE_LEVEL[d.year] * MARKUP.get(cb.part_category.iat[c], 1.28), 2)
                    serial = ""
                    if channel == "Service Work Order" or rng.random() < 0.35:
                        pool = serial_by_bp.get((b_id, cb.primary_product_id.iat[c])) or serial_by_b.get(b_id, [""])
                        serial = pool[int(rng.integers(len(pool)))]
                    filled = min(qty, on_hand[c])
                    short = qty - filled
                    on_hand[c] -= filled
                    lost = 0
                    if short and (cb.criticality.iat[c] == "Low" or rng.random() < 0.3):
                        lost = short  # customer sources elsewhere
                    bo = short - lost
                    sales.append([so, ln, order_ts, b_id, cust, cust_name[cust], channel, serial,
                                  cb.part_id.iat[c], cb.part_number.iat[c], cb.part_description.iat[c],
                                  qty, price, round(qty * price, 2), req.isoformat()])
                    demand.append([f"DM{next_id('dm'):08d}", so, ln, b_id, cb.part_id.iat[c], d.isoformat(),
                                   channel, qty, filled, bo, 0, "", lost])
                    if filled:
                        post(d, c, "Goods Issue", -filled, "SO", f"{so}-{ln}")
                        if not is_fluid[c] and rng.random() < 0.015:
                            ret_day = di + int(rng.integers(3, 30))
                            returns[ret_day].append((c, max(1, filled // 2), f"{so}-{ln}"))
                    if bo:
                        backlog[c].append([len(demand) - 1, bo])
                        backlog_qty[c] += bo
                k += n_lines

        # 3. Cycle counts
        if d.weekday() < 5:
            for c in rng.choice(C, size=max(1, C // 400), replace=False):
                if rng.random() < 0.3:
                    delta = int(rng.choice([-3, -2, -1, -1, -1, 1, 1, 2]))
                    delta = max(delta, -int(on_hand[c]))
                    if delta:
                        on_hand[c] += delta
                        post(d, c, "Cycle Count Adjustment", delta, "COUNT", f"CC{d:%Y%m%d}")

        # 4. Replenishment: transfer from a sibling branch with excess, else purchase order
        if d.weekday() >= 5:
            continue
        position = on_hand + on_order - backlog_qty
        need = np.flatnonzero(position <= rop)
        po_groups = defaultdict(list)
        for c in need:
            qty = int(order_qty[c] * math.ceil((rop[c] - position[c] + 1) / order_qty[c]))
            if backlog_qty[c] > 0 or cb.criticality.iat[c] == "High":
                donors = [s for s in siblings[cb.part_id.iat[c]]
                          if s != c and on_hand[s] - rop[s] - backlog_qty[s] >= qty]
                if donors and rng.random() < 0.6:
                    s = donors[int(rng.integers(len(donors)))]
                    tr = f"TO{next_id('to'):07d}"
                    on_hand[s] -= qty
                    post(d, s, "Transfer Out", -qty, "TRANSFER", tr)
                    on_order[c] += qty
                    arrivals[business_day(di + (1 if region[s] == region[c] else 2))].append((c, qty, tr, "TR"))
                    continue
            po_groups[(cb.branch_id.iat[c], cb.primary_supplier_id.iat[c], bool(backlog_qty[c]))].append((c, qty))

        for (b_id, s_id, emergency), lines in po_groups.items():
            po_no = f"45{next_id('po'):08d}"
            for ln, (c, qty) in enumerate(lines, start=1):
                planned = 1 if (emergency and is_oem[c]) else int(lt_plan[c])
                actual = max(1, round(planned * rng.lognormal(-0.12, 0.12)))
                if undercarriage[c] and date(2025, 3, 1) <= d <= date(2025, 8, 31):
                    actual = round(actual * 1.8)  # undercarriage supply constraint
                if rng.random() > otd[c]:
                    actual += int(rng.integers(2, max(4, planned + 2)))
                promised = days[min(business_day(di + planned), len(days) - 1)] if di + planned < len(days)                     else d + timedelta(days=planned)
                unit_cost = round(cost[c] * PRICE_LEVEL[d.year], 2)
                pos.append([po_no, ln, d.isoformat(), b_id, s_id, cb.part_id.iat[c], cb.part_number.iat[c],
                            qty, cb.unit_of_measure.iat[c], unit_cost, round(qty * unit_cost, 2),
                            "Emergency" if emergency else "Stock", promised.isoformat(), 0, ""])
                on_order[c] += qty
                row = len(pos) - 1
                arrive = business_day(di + actual)
                if qty > 1 and rng.random() < 0.07:  # partial shipment
                    first = max(1, int(qty * rng.uniform(0.4, 0.8)))
                    arrivals[arrive].append((c, first, (row, qty), "PO"))
                    arrivals[business_day(arrive + int(rng.integers(3, 15)))].append((c, qty - first, (row, qty), "PO"))
                else:
                    arrivals[arrive].append((c, qty, (row, qty), "PO"))

    # --- Assemble DataFrames ------------------------------------------------------------------------
    sales_df = pd.DataFrame(sales, columns=[
        "sales_order_id", "so_line", "order_timestamp", "branch_id", "customer_id", "customer_name",
        "order_channel", "equipment_serial", "part_id", "part_number", "part_description",
        "qty_ordered", "unit_price_usd", "extended_price_usd", "requested_date"])
    demand_df = pd.DataFrame(demand, columns=[
        "demand_id", "sales_order_id", "so_line", "branch_id", "part_id", "demand_date", "demand_source",
        "qty_demanded", "qty_filled_from_stock", "qty_backordered", "qty_backorder_filled",
        "last_fill_date", "qty_lost_sale"])
    demand_df["fill_status"] = np.select(
        [demand_df.qty_filled_from_stock == demand_df.qty_demanded,
         demand_df.qty_lost_sale == demand_df.qty_demanded,
         (demand_df.qty_backordered > 0) & (demand_df.qty_backorder_filled == demand_df.qty_backordered),
         demand_df.qty_backordered > demand_df.qty_backorder_filled],
        ["Filled", "Lost Sale", "Backorder Filled", "Backorder Open"], "Partial - Balance Lost")

    # Sales line status follows fulfillment
    shipped = demand_df.qty_filled_from_stock + demand_df.qty_backorder_filled
    sales_df["qty_shipped"] = shipped.values
    sales_df["line_status"] = np.select(
        [demand_df.fill_status.isin(["Filled", "Backorder Filled"]), demand_df.fill_status == "Lost Sale",
         demand_df.fill_status == "Backorder Open"],
        ["Invoiced", "Cancelled", "Backordered"], "Invoiced - Balance Cancelled")
    sales_df["invoice_date"] = np.where(
        sales_df.line_status == "Invoiced",
        np.where(demand_df.last_fill_date != "", demand_df.last_fill_date, sales_df.order_timestamp.str[:10]),
        np.where(sales_df.line_status == "Invoiced - Balance Cancelled", sales_df.order_timestamp.str[:10], ""))

    po_df = pd.DataFrame(pos, columns=[
        "po_number", "po_line", "po_date", "branch_id", "supplier_id", "part_id", "part_number",
        "qty_ordered", "unit_of_measure", "unit_cost_usd", "line_value_usd", "order_type", "promised_date",
        "qty_received", "last_receipt_date"])
    po_df["line_status"] = np.select(
        [po_df.qty_received >= po_df.qty_ordered, po_df.qty_received > 0],
        ["Closed", "Partially Received"], "Open")

    gr_df = pd.DataFrame(grs, columns=[
        "gr_number", "gr_line", "receipt_date", "po_number", "po_line", "branch_id", "supplier_id", "part_id",
        "part_number", "qty_received", "qty_accepted", "qty_rejected", "unit_cost_usd", "rejection_reason"])

    inv_df = pd.DataFrame(inv, columns=[
        "txn_id", "txn_timestamp", "branch_id", "part_id", "part_number", "txn_type", "qty", "unit_of_measure",
        "reference_type", "reference_id", "balance_after", "unit_cost_usd"])
    inv_df = inv_df.sort_values(["txn_timestamp", "txn_id"], kind="stable").reset_index(drop=True)

    return {
        "inventory_transactions": inv_df,
        "purchase_orders": po_df,
        "demand_transactions": demand_df,
        "goods_receipts": gr_df,
        "sales_orders": sales_df,
    }


# ---------------------------------------------------------------------------
# Defect injection
# ---------------------------------------------------------------------------

KEYS = {"sales_orders": ["sales_order_id", "so_line"], "demand_transactions": ["demand_id"],
        "purchase_orders": ["po_number", "po_line"], "goods_receipts": ["gr_number", "gr_line"],
        "inventory_transactions": ["txn_id"]}


class Messer:
    def __init__(self, rng):
        self.rng = rng
        self.logs = []

    def key(self, df, table, idx):
        return df.loc[idx, KEYS[table]].astype(str).agg("-".join, axis=1).values

    def pick(self, df, frac, col=None, where=None):
        mask = np.ones(len(df), dtype=bool)
        if col is not None:
            mask &= df[col].notna().values & (df[col].astype(str) != "").values
        if where is not None:
            mask &= where(df).values
        idx = df.index[mask]
        n = min(len(idx), max(1, int(len(df) * frac)))
        return self.rng.choice(idx, size=n, replace=False)

    def log(self, table, keys, col, issue, dim, sev, old, new):
        self.logs.append(pd.DataFrame({"table": table, "record_key": keys, "column": col, "issue_type": issue,
                                       "dq_dimension": dim, "severity": sev,
                                       "golden_value": old, "raw_value": new}))

    def apply(self, df, table, frac, col, fn, issue, dim, sev, need_value=True, where=None):
        idx = self.pick(df, frac, col if need_value else None, where)
        old = df.loc[idx, col].tolist()
        new = [fn(v) for v in old]
        df.loc[idx, col] = pd.Series(new, index=idx, dtype=object)
        self.log(table, self.key(df, table, idx), col, issue, dim, sev, old, new)

    def duplicate(self, df, table, frac, issue, sev, mutate=None):
        idx = self.pick(df, frac)
        dups = df.loc[idx].copy()
        for col, fn in (mutate or {}).items():
            dups[col] = [fn(v) for v in dups[col]]
        self.log(table, self.key(df, table, idx), "*", issue, "Uniqueness", sev, None, None)
        return pd.concat([df, dups], ignore_index=True)


def build_raw(golden, master_raw_suppliers, rng):
    m = Messer(rng)
    raw = {k: v.astype(object).copy() for k, v in golden.items()}
    r = rng.random
    choice = lambda xs: xs[int(rng.integers(len(xs)))]

    def messy_date(v):
        d = datetime.fromisoformat(str(v)[:19])
        return choice([d.strftime("%m/%d/%Y"), d.strftime("%d-%b-%Y"), d.strftime("%Y%m%d"),
                       str((d - datetime(1899, 12, 30)).days)])  # last one = Excel serial number

    def part_variant(v):
        return choice([v.replace("-", ""), v.lower(), f" {v}", v.replace("-", " ")])

    dup_supplier_ids = master_raw_suppliers

    # --- Sales orders ------------------------------------------------------------------------------
    t = "sales_orders"
    df = m.duplicate(raw[t], t, 0.004, "Order line sent twice by interface", "High")
    m.apply(df, t, 0.003, "branch_id", lambda v: None, "Missing branch", "Completeness", "High")
    m.apply(df, t, 0.01, "part_number", part_variant, "Part number format not standardized", "Validity", "Medium")
    m.apply(df, t, 0.002, "part_id", lambda v: "PT99999", "Part not in master", "Integrity", "High")
    m.apply(df, t, 0.002, "qty_ordered", lambda v: -v, "Negative quantity on sales line", "Validity", "High")
    m.apply(df, t, 0.002, "qty_ordered", lambda v: None, "Missing quantity", "Completeness", "High")
    m.apply(df, t, 0.01, "order_timestamp", messy_date, "Non-standard date format", "Validity", "Low")
    m.apply(df, t, 0.001, "order_timestamp", lambda v: "2027" + str(v)[4:], "Order date in the future",
            "Validity", "High")
    m.apply(df, t, 0.003, "unit_price_usd", lambda v: 0, "Zero unit price", "Validity", "Medium")
    m.apply(df, t, 0.003, "extended_price_usd", lambda v: round(float(v) * choice([10, 0.1, 1.07]), 2),
            "Extended price does not equal qty x price", "Consistency", "Medium")
    m.apply(df, t, 0.02, "customer_name",
            lambda v: choice([v.upper(), v.replace(" LLC", "").replace(" Inc.", ""), v + " ", v.replace("&", "and")]),
            "Customer name variant", "Consistency", "Low")
    raw[t] = df

    # --- Demand transactions -----------------------------------------------------------------------
    t = "demand_transactions"
    df = m.duplicate(raw[t], t, 0.005, "Duplicate demand transaction", "High",
                     {"demand_id": lambda v: "DM9" + v[3:]})
    m.apply(df, t, 0.003, "qty_demanded", lambda v: None, "Missing demand quantity", "Completeness", "High")
    m.apply(df, t, 0.002, "part_id", lambda v: choice(["PT99999", "", "UNKNOWN"]),
            "Invalid part reference", "Integrity", "High")
    m.apply(df, t, 0.002, "demand_date", lambda v: choice([None, "1900-01-01", "0000-00-00"]),
            "Invalid or missing transaction date", "Validity", "High")
    m.apply(df, t, 0.002, "qty_filled_from_stock", lambda v: int(v) + int(rng.integers(1, 5)),
            "Filled quantity exceeds demanded", "Validity", "Medium")
    m.apply(df, t, 0.003, "branch_id", lambda v: choice(["Richmond", "B099", "b001"]),
            "Branch reference not a valid ID", "Integrity", "High")
    raw[t] = df

    # --- Purchase orders ---------------------------------------------------------------------------
    t = "purchase_orders"
    df = m.duplicate(raw[t], t, 0.003, "Duplicate PO line", "High")
    m.apply(df, t, 0.005, "supplier_id", lambda v: choice(["S099"] + dup_supplier_ids),
            "Supplier ID invalid or a duplicate master record", "Integrity", "High")
    m.apply(df, t, 0.01, "promised_date", lambda v: None, "Missing promised date", "Completeness", "Medium")
    m.apply(df, t, 0.003, "promised_date",
            lambda v: (date.fromisoformat(v) - timedelta(days=int(rng.integers(15, 60)))).isoformat(),
            "Promised date before PO date", "Validity", "Medium")
    m.apply(df, t, 0.002, "qty_ordered", lambda v: choice([0, -int(v)]), "Zero or negative order quantity",
            "Validity", "High")
    m.apply(df, t, 0.003, "unit_cost_usd", lambda v: f"${float(v):,.2f}", "Unit cost stored as currency text",
            "Validity", "Medium")
    m.apply(df, t, 0.005, "line_status", lambda v: "Closed", "Closed but not fully received", "Consistency",
            "Medium", where=lambda x: x.line_status != "Closed")
    m.apply(df, t, 0.004, "last_receipt_date", lambda v: None, "Missing receipt date on received line",
            "Completeness", "Medium")
    raw[t] = df

    # --- Goods receipts ----------------------------------------------------------------------------
    t = "goods_receipts"
    df = m.duplicate(raw[t], t, 0.005, "Receipt posted twice", "High",
                     {"gr_number": lambda v: "59" + v[2:]})
    m.apply(df, t, 0.005, "receipt_date", lambda v: None, "Missing receipt date", "Completeness", "High")
    m.apply(df, t, 0.003, "receipt_date", lambda v: (date.fromisoformat(v) - timedelta(days=120)).isoformat(),
            "Receipt date before PO date", "Validity", "High")
    m.apply(df, t, 0.003, "po_number", lambda v: "45" + "9" * 8, "Receipt against unknown PO", "Integrity", "High")
    m.apply(df, t, 0.003, "qty_received", lambda v: int(v) * choice([2, 10]), "Over-receipt vs PO quantity",
            "Validity", "Medium")
    m.apply(df, t, 0.008, "part_number", part_variant, "Part number format not standardized", "Validity", "Low")
    raw[t] = df

    # --- Inventory transactions --------------------------------------------------------------------
    t = "inventory_transactions"
    df = m.duplicate(raw[t], t, 0.003, "Duplicate inventory posting", "High")
    m.apply(df, t, 0.002, "balance_after", lambda v: -int(rng.integers(1, 20)), "Negative on-hand balance",
            "Validity", "High")
    m.apply(df, t, 0.002, "branch_id", lambda v: None, "Missing branch", "Completeness", "High")
    m.apply(df, t, 0.01, "txn_type",
            lambda v: {"Goods Issue": choice(["ISS", "issue", "GI"]), "Goods Receipt": choice(["RCPT", "GR", "receipt"]),
                       }.get(v, v.upper()),
            "Transaction type code not standardized", "Consistency", "Low")
    m.apply(df, t, 0.003, "txn_timestamp", messy_date, "Non-standard date format", "Validity", "Low")
    m.apply(df, t, 0.001, "part_id", lambda v: None, "Missing part reference", "Completeness", "High")
    raw[t] = df

    return raw, pd.concat(m.logs, ignore_index=True)


# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--scale", type=float, default=1.0, help="multiplier on transaction volume")
    args = parser.parse_args()

    rng = np.random.default_rng(args.seed)
    master = load_master()
    golden = simulate(master, rng, args.scale)

    raw_sup = pd.read_csv(HERE / "master_data" / "raw" / "supplier_master.csv").supplier_id
    dup_ids = sorted(set(raw_sup.dropna()) - set(master["supplier_master"].supplier_id))
    raw, log = build_raw(golden, dup_ids, rng)

    for sub, data in (("golden", golden), ("raw", raw)):
        (OUT_DIR / sub).mkdir(parents=True, exist_ok=True)
        for name, df in data.items():
            df.to_csv(OUT_DIR / sub / f"{name}.csv", index=False)
    log.to_csv(OUT_DIR / "dq_issue_log.csv", index=False)

    # Small committed sample (full extracts are git-ignored - regenerate with this script)
    for sub, data in (("golden", golden), ("raw", raw)):
        (OUT_DIR / "sample" / sub).mkdir(parents=True, exist_ok=True)
        for name, df in data.items():
            df.head(SAMPLE_ROWS).to_csv(OUT_DIR / "sample" / sub / f"{name}.csv", index=False)

    print(f"{'table':<26}{'golden':>10}{'raw':>10}{'issues':>8}")
    for name in golden:
        print(f"{name:<26}{len(golden[name]):>10,}{len(raw[name]):>10,}{(log.table == name).sum():>8,}")
    print(f"\nTotal logged issues: {len(log):,}  ->  {OUT_DIR}")


if __name__ == "__main__":
    main()
