/*
    06_agent_security.sql
    Least-privilege database identities for the AI agents.

    The agents connect with the developer's Windows login, then immediately switch to a database user that
    can only read the schemas they need:  EXECUTE AS USER = 'dq_agent_reader'.
    Even if a model asked for it, that identity cannot insert, update, delete, or read the mart.

    The user has no login: it cannot be used to connect directly, only impersonated.
*/
IF USER_ID(N'dq_agent_reader') IS NULL
    CREATE USER dq_agent_reader WITHOUT LOGIN;
GO

GRANT SELECT ON SCHEMA::dq    TO dq_agent_reader;
GRANT SELECT ON SCHEMA::audit TO dq_agent_reader;
GRANT SELECT ON SCHEMA::raw   TO dq_agent_reader;
GO
