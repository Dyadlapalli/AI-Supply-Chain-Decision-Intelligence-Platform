# Source System Landscape

## Overview

This platform is designed to simulate a real-world enterprise supply chain environment where data originates from multiple systems rather than a single database.

The goal is not simply to analyze inventory, but to demonstrate how data from operational systems, external services, and business-managed sources can be integrated into a unified decision intelligence platform.

---

# ERP Platform

## Business Purpose

The ERP system serves as the primary system of record for purchasing, inventory, product, and supplier transactions.

In most organizations, this is where the majority of operational supply chain activity is captured.

## Example Platforms

- SAP S/4HANA
- Oracle ERP
- Microsoft Dynamics 365
- Infor

## Data Consumed

### Inventory Transactions

- Inventory On Hand
- Inventory Movements
- Inventory Reservations

### Purchase Orders

- Purchase Order Header
- Purchase Order Lines
- Goods Receipts

### Demand Transactions

- Customer Orders
- Fulfilled Demand
- Backorders

---

# Operational Database

## Business Purpose

Organizations often move ERP data into a reporting or operational database for analytics and reporting purposes.

## Example Platforms

- SQL Server
- Azure SQL
- PostgreSQL
- Snowflake
- Databricks

## Data Consumed

- Inventory Snapshots
- Purchase Orders
- Demand Transactions
- Historical Performance Data

---

# Business Managed Data

## Business Purpose

Not all supply chain information is maintained within enterprise systems.

Many planning decisions rely on business-owned files.

## Data Sources

### Excel

Examples:

- Safety Stock Targets
- Inventory Policies
- Supplier Exception Lists
- Critical Parts Lists

### SharePoint

Examples:

- Forecast Overrides
- Planning Assumptions
- Monthly Planning Adjustments

---

# External Data Sources

## Business Purpose

External data provides additional context for planning and forecasting.

### Examples

Weather Data

- Storm Activity
- Severe Weather Events

Economic Indicators

- Construction Spending
- Housing Starts
- Inflation

Transportation Metrics

- Fuel Costs
- Freight Indicators

## Access Method

Typically accessed through REST APIs.

---

# Master Data

## Business Purpose

Provides a governed source of reference information used throughout the platform.

## Data Domains

### Parts

- Part Number
- Description
- Category
- Criticality

### Suppliers

- Supplier Name
- Tier
- Lead Time

### Branches

- Branch
- Region
- State

### Equipment

- Equipment Model
- Equipment Family

---

# Future-State Architecture

ERP Systems
↓
Operational Database
↓
Business Managed Files
↓
External APIs
↓
Master Data
↓
Data Quality Layer
↓
Curated Analytics Model
↓
Forecasting Engine
↓
AI Agents
↓
Interactive Power BI Application
↓
Business Decisions

---

# Why This Matters

The purpose of this architecture is to demonstrate how information from multiple systems can be brought together to support inventory planning, supplier management, forecasting, scenario planning, and executive decision making.

This reflects the type of data ecosystem commonly found within modern supply chain organizations.
