/*
    ICFWalk SQL Server database definition
    Target: Microsoft SQL Server 2016 or later
    Application: Adobe ColdFusion 2023

    Design goals
    ------------
    1. Questions, sections, choices, variables, and approved display rules are data driven.
    2. Published instrument versions and completed walk history can be retained permanently.
    3. District and school access is assigned through role plus organizational scope.
    4. Walks use optimistic concurrency through SQL Server rowversion columns.
    5. Reporting indexes support school, date, item, option, and variable trend analysis.
    6. The script creates objects only. It never drops or replaces existing objects.

    Important application responsibilities
    --------------------------------------
    - ColdFusion must use parameterized cfqueryparam values for all database input.
    - Authorization must be checked on the server for every request.
    - Published versions and their child definitions must be treated as immutable.
    - Item-type validation and rule-reference validation occur before publication.
    - Every response must be validated against the walk's pinned instrument version.
    - Narrative notes and teacher information must be excluded from aggregate reporting.
    - walk_revision and audit_event are append-only application records.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    IF SCHEMA_ID(N'icf') IS NULL
        EXEC(N'CREATE SCHEMA [icf] AUTHORIZATION [dbo];');

    IF EXISTS
    (
        SELECT 1
        FROM sys.tables
        WHERE schema_id = SCHEMA_ID(N'icf')
    )
    BEGIN
        ;THROW 50001,
            'The icf schema already contains tables. No changes were made. Use a reviewed migration script for an existing installation.',
            1;
    END;

    /* ================================================================
       ACCESS AND ORGANIZATIONAL SCOPE
       ================================================================ */

    CREATE TABLE [icf].[org_unit]
    (
        [org_unit_id]         uniqueidentifier NOT NULL
            CONSTRAINT [DF_org_unit_id] DEFAULT (NEWSEQUENTIALID()),
        [parent_org_unit_id]  uniqueidentifier NULL,
        [org_unit_code]       nvarchar(50) NOT NULL,
        [org_unit_type]       nvarchar(30) NOT NULL,
        [name]                nvarchar(200) NOT NULL,
        [active]              bit NOT NULL
            CONSTRAINT [DF_org_unit_active] DEFAULT (1),
        [created_at]          datetime2(3) NOT NULL
            CONSTRAINT [DF_org_unit_created] DEFAULT (SYSUTCDATETIME()),
        [updated_at]          datetime2(3) NOT NULL
            CONSTRAINT [DF_org_unit_updated] DEFAULT (SYSUTCDATETIME()),
        [row_version]         rowversion NOT NULL,

        CONSTRAINT [PK_org_unit]
            PRIMARY KEY CLUSTERED ([org_unit_id]),
        CONSTRAINT [UQ_org_unit_code]
            UNIQUE ([org_unit_code]),
        CONSTRAINT [FK_org_unit_parent]
            FOREIGN KEY ([parent_org_unit_id])
            REFERENCES [icf].[org_unit] ([org_unit_id]),
        CONSTRAINT [CK_org_unit_not_self_parent]
            CHECK ([parent_org_unit_id] IS NULL OR [parent_org_unit_id] <> [org_unit_id]),
        CONSTRAINT [CK_org_unit_code_not_blank]
            CHECK (LEN(LTRIM(RTRIM([org_unit_code]))) > 0),
        CONSTRAINT [CK_org_unit_name_not_blank]
            CHECK (LEN(LTRIM(RTRIM([name]))) > 0)
    );

    CREATE TABLE [icf].[app_user]
    (
        [user_id]             uniqueidentifier NOT NULL
            CONSTRAINT [DF_app_user_id] DEFAULT (NEWSEQUENTIALID()),
        [identity_subject]    nvarchar(255) NOT NULL,
        [display_name]        nvarchar(200) NOT NULL,
        [email]               nvarchar(320) NULL,
        [active]              bit NOT NULL
            CONSTRAINT [DF_app_user_active] DEFAULT (1),
        [last_sign_in_at]     datetime2(3) NULL,
        [created_at]          datetime2(3) NOT NULL
            CONSTRAINT [DF_app_user_created] DEFAULT (SYSUTCDATETIME()),
        [updated_at]          datetime2(3) NOT NULL
            CONSTRAINT [DF_app_user_updated] DEFAULT (SYSUTCDATETIME()),
        [row_version]         rowversion NOT NULL,

        CONSTRAINT [PK_app_user]
            PRIMARY KEY CLUSTERED ([user_id]),
        CONSTRAINT [UQ_app_user_identity]
            UNIQUE ([identity_subject]),
        CONSTRAINT [CK_app_user_subject_not_blank]
            CHECK (LEN(LTRIM(RTRIM([identity_subject]))) > 0),
        CONSTRAINT [CK_app_user_name_not_blank]
            CHECK (LEN(LTRIM(RTRIM([display_name]))) > 0)
    );

    CREATE UNIQUE INDEX [UX_app_user_email]
        ON [icf].[app_user] ([email])
        WHERE [email] IS NOT NULL;

    CREATE TABLE [icf].[app_role]
    (
        [role_id]                     uniqueidentifier NOT NULL
            CONSTRAINT [DF_app_role_id] DEFAULT (NEWSEQUENTIALID()),
        [role_code]                   nvarchar(60) NOT NULL,
        [name]                        nvarchar(150) NOT NULL,
        [description]                 nvarchar(500) NULL,
        [scope_type]                  nvarchar(20) NOT NULL,
        [can_create_walk]             bit NOT NULL
            CONSTRAINT [DF_role_create_walk] DEFAULT (0),
        [can_open_walk_details]       bit NOT NULL
            CONSTRAINT [DF_role_open_details] DEFAULT (0),
        [can_edit_owned_walks]        bit NOT NULL
            CONSTRAINT [DF_role_edit_owned] DEFAULT (0),
        [can_view_aggregate_reports]  bit NOT NULL
            CONSTRAINT [DF_role_view_reports] DEFAULT (0),
        [can_manage_instruments]      bit NOT NULL
            CONSTRAINT [DF_role_manage_instruments] DEFAULT (0),
        [active]                      bit NOT NULL
            CONSTRAINT [DF_app_role_active] DEFAULT (1),
        [created_at]                  datetime2(3) NOT NULL
            CONSTRAINT [DF_app_role_created] DEFAULT (SYSUTCDATETIME()),
        [updated_at]                  datetime2(3) NOT NULL
            CONSTRAINT [DF_app_role_updated] DEFAULT (SYSUTCDATETIME()),
        [row_version]                 rowversion NOT NULL,

        CONSTRAINT [PK_app_role]
            PRIMARY KEY CLUSTERED ([role_id]),
        CONSTRAINT [UQ_app_role_code]
            UNIQUE ([role_code]),
        CONSTRAINT [CK_app_role_scope]
            CHECK ([scope_type] IN (N'GLOBAL', N'DISTRICT', N'SCHOOL')),
        CONSTRAINT [CK_app_role_code_not_blank]
            CHECK (LEN(LTRIM(RTRIM([role_code]))) > 0)
    );

    CREATE TABLE [icf].[user_role_scope]
    (
        [user_role_scope_id]  uniqueidentifier NOT NULL
            CONSTRAINT [DF_user_role_scope_id] DEFAULT (NEWSEQUENTIALID()),
        [user_id]             uniqueidentifier NOT NULL,
        [role_id]             uniqueidentifier NOT NULL,
        [org_unit_id]         uniqueidentifier NOT NULL,
        [effective_start]     datetime2(3) NOT NULL
            CONSTRAINT [DF_user_role_scope_start] DEFAULT (SYSUTCDATETIME()),
        [effective_end]       datetime2(3) NULL,
        [include_descendants] bit NOT NULL
            CONSTRAINT [DF_user_role_scope_desc] DEFAULT (0),
        [created_by_user_id]  uniqueidentifier NULL,
        [created_at]          datetime2(3) NOT NULL
            CONSTRAINT [DF_user_role_scope_created] DEFAULT (SYSUTCDATETIME()),
        [row_version]         rowversion NOT NULL,

        CONSTRAINT [PK_user_role_scope]
            PRIMARY KEY CLUSTERED ([user_role_scope_id]),
        CONSTRAINT [UQ_user_role_scope_assignment]
            UNIQUE ([user_id], [role_id], [org_unit_id], [effective_start]),
        CONSTRAINT [FK_user_role_scope_user]
            FOREIGN KEY ([user_id]) REFERENCES [icf].[app_user] ([user_id]),
        CONSTRAINT [FK_user_role_scope_role]
            FOREIGN KEY ([role_id]) REFERENCES [icf].[app_role] ([role_id]),
        CONSTRAINT [FK_user_role_scope_org]
            FOREIGN KEY ([org_unit_id]) REFERENCES [icf].[org_unit] ([org_unit_id]),
        CONSTRAINT [FK_user_role_scope_creator]
            FOREIGN KEY ([created_by_user_id]) REFERENCES [icf].[app_user] ([user_id]),
        CONSTRAINT [CK_user_role_scope_dates]
            CHECK ([effective_end] IS NULL OR [effective_end] > [effective_start])
    );

    /* ================================================================
       INSTRUMENT CONFIGURATION
       ================================================================ */

    CREATE TABLE [icf].[instrument]
    (
        [instrument_id]  uniqueidentifier NOT NULL
            CONSTRAINT [DF_instrument_id] DEFAULT (NEWSEQUENTIALID()),
        [code]           nvarchar(60) NOT NULL,
        [name]           nvarchar(200) NOT NULL,
        [description]    nvarchar(1000) NULL,
        [active]         bit NOT NULL
            CONSTRAINT [DF_instrument_active] DEFAULT (1),
        [created_at]     datetime2(3) NOT NULL
            CONSTRAINT [DF_instrument_created] DEFAULT (SYSUTCDATETIME()),
        [updated_at]     datetime2(3) NOT NULL
            CONSTRAINT [DF_instrument_updated] DEFAULT (SYSUTCDATETIME()),
        [row_version]    rowversion NOT NULL,

        CONSTRAINT [PK_instrument]
            PRIMARY KEY CLUSTERED ([instrument_id]),
        CONSTRAINT [UQ_instrument_code]
            UNIQUE ([code]),
        CONSTRAINT [CK_instrument_code_not_blank]
            CHECK (LEN(LTRIM(RTRIM([code]))) > 0),
        CONSTRAINT [CK_instrument_name_not_blank]
            CHECK (LEN(LTRIM(RTRIM([name]))) > 0)
    );

    CREATE TABLE [icf].[instrument_version]
    (
        [version_id]                uniqueidentifier NOT NULL
            CONSTRAINT [DF_instrument_version_id] DEFAULT (NEWSEQUENTIALID()),
        [instrument_id]             uniqueidentifier NOT NULL,
        [version_label]             nvarchar(100) NOT NULL,
        [status]                    nvarchar(20) NOT NULL
            CONSTRAINT [DF_instrument_version_status] DEFAULT (N'DRAFT'),
        [effective_start]           datetime2(3) NULL,
        [effective_end]             datetime2(3) NULL,
        [compiled_snapshot_json]    nvarchar(max) NULL,
        [checksum_sha256]           char(64) NULL,
        [created_by_user_id]        uniqueidentifier NULL,
        [published_by_user_id]      uniqueidentifier NULL,
        [created_at]                datetime2(3) NOT NULL
            CONSTRAINT [DF_instrument_version_created] DEFAULT (SYSUTCDATETIME()),
        [published_at]              datetime2(3) NULL,
        [updated_at]                datetime2(3) NOT NULL
            CONSTRAINT [DF_instrument_version_updated] DEFAULT (SYSUTCDATETIME()),
        [row_version]               rowversion NOT NULL,

        CONSTRAINT [PK_instrument_version]
            PRIMARY KEY CLUSTERED ([version_id]),
        CONSTRAINT [UQ_instrument_version_label]
            UNIQUE ([instrument_id], [version_label]),
        CONSTRAINT [FK_instrument_version_instrument]
            FOREIGN KEY ([instrument_id]) REFERENCES [icf].[instrument] ([instrument_id]),
        CONSTRAINT [FK_instrument_version_creator]
            FOREIGN KEY ([created_by_user_id]) REFERENCES [icf].[app_user] ([user_id]),
        CONSTRAINT [FK_instrument_version_publisher]
            FOREIGN KEY ([published_by_user_id]) REFERENCES [icf].[app_user] ([user_id]),
        CONSTRAINT [CK_instrument_version_status]
            CHECK ([status] IN (N'DRAFT', N'PUBLISHED', N'RETIRED')),
        CONSTRAINT [CK_instrument_version_dates]
            CHECK ([effective_end] IS NULL OR [effective_start] IS NULL OR [effective_end] > [effective_start]),
        CONSTRAINT [CK_instrument_version_snapshot_json]
            CHECK ([compiled_snapshot_json] IS NULL OR ISJSON([compiled_snapshot_json]) = 1),
        CONSTRAINT [CK_instrument_version_publish_values]
            CHECK
            (
                [status] = N'DRAFT'
                OR
                (
                    [effective_start] IS NOT NULL
                    AND [published_at] IS NOT NULL
                    AND [compiled_snapshot_json] IS NOT NULL
                    AND [checksum_sha256] IS NOT NULL
                )
            )
    );

    CREATE TABLE [icf].[section_definition]
    (
        [section_id]          uniqueidentifier NOT NULL
            CONSTRAINT [DF_section_definition_id] DEFAULT (NEWSEQUENTIALID()),
        [version_id]          uniqueidentifier NOT NULL,
        [parent_section_id]   uniqueidentifier NULL,
        [section_key]         nvarchar(100) NOT NULL,
        [display_order]       int NOT NULL,
        [title]               nvarchar(300) NOT NULL,
        [instructions]        nvarchar(max) NULL,
        [notes_enabled]       bit NOT NULL
            CONSTRAINT [DF_section_notes_enabled] DEFAULT (0),
        [settings_json]       nvarchar(max) NULL,
        [active]              bit NOT NULL
            CONSTRAINT [DF_section_active] DEFAULT (1),
        [created_at]          datetime2(3) NOT NULL
            CONSTRAINT [DF_section_created] DEFAULT (SYSUTCDATETIME()),
        [updated_at]          datetime2(3) NOT NULL
            CONSTRAINT [DF_section_updated] DEFAULT (SYSUTCDATETIME()),
        [row_version]         rowversion NOT NULL,

        CONSTRAINT [PK_section_definition]
            PRIMARY KEY CLUSTERED ([section_id]),
        CONSTRAINT [UQ_section_id_version]
            UNIQUE ([section_id], [version_id]),
        CONSTRAINT [UQ_section_version_key]
            UNIQUE ([version_id], [section_key]),
        CONSTRAINT [FK_section_version]
            FOREIGN KEY ([version_id]) REFERENCES [icf].[instrument_version] ([version_id]),
        CONSTRAINT [FK_section_parent_same_version]
            FOREIGN KEY ([parent_section_id], [version_id])
            REFERENCES [icf].[section_definition] ([section_id], [version_id]),
        CONSTRAINT [CK_section_not_self_parent]
            CHECK ([parent_section_id] IS NULL OR [parent_section_id] <> [section_id]),
        CONSTRAINT [CK_section_order]
            CHECK ([display_order] >= 0),
        CONSTRAINT [CK_section_key_not_blank]
            CHECK (LEN(LTRIM(RTRIM([section_key]))) > 0),
        CONSTRAINT [CK_section_settings_json]
            CHECK ([settings_json] IS NULL OR ISJSON([settings_json]) = 1)
    );

    CREATE TABLE [icf].[response_set]
    (
        [response_set_id]  uniqueidentifier NOT NULL
            CONSTRAINT [DF_response_set_id] DEFAULT (NEWSEQUENTIALID()),
        [version_id]       uniqueidentifier NOT NULL,
        [response_set_key] nvarchar(100) NOT NULL,
        [name]             nvarchar(200) NOT NULL,
        [selection_mode]   nvarchar(20) NOT NULL,
        [settings_json]    nvarchar(max) NULL,
        [active]           bit NOT NULL
            CONSTRAINT [DF_response_set_active] DEFAULT (1),
        [created_at]       datetime2(3) NOT NULL
            CONSTRAINT [DF_response_set_created] DEFAULT (SYSUTCDATETIME()),
        [updated_at]       datetime2(3) NOT NULL
            CONSTRAINT [DF_response_set_updated] DEFAULT (SYSUTCDATETIME()),
        [row_version]      rowversion NOT NULL,

        CONSTRAINT [PK_response_set]
            PRIMARY KEY CLUSTERED ([response_set_id]),
        CONSTRAINT [UQ_response_set_id_version]
            UNIQUE ([response_set_id], [version_id]),
        CONSTRAINT [UQ_response_set_version_key]
            UNIQUE ([version_id], [response_set_key]),
        CONSTRAINT [FK_response_set_version]
            FOREIGN KEY ([version_id]) REFERENCES [icf].[instrument_version] ([version_id]),
        CONSTRAINT [CK_response_set_mode]
            CHECK ([selection_mode] IN (N'SINGLE', N'MULTI')),
        CONSTRAINT [CK_response_set_key_not_blank]
            CHECK (LEN(LTRIM(RTRIM([response_set_key]))) > 0),
        CONSTRAINT [CK_response_set_settings_json]
            CHECK ([settings_json] IS NULL OR ISJSON([settings_json]) = 1)
    );

    CREATE TABLE [icf].[response_option]
    (
        [option_id]       uniqueidentifier NOT NULL
            CONSTRAINT [DF_response_option_id] DEFAULT (NEWSEQUENTIALID()),
        [response_set_id] uniqueidentifier NOT NULL,
        [option_key]      nvarchar(100) NOT NULL,
        [stored_code]     nvarchar(100) NOT NULL,
        [label]           nvarchar(500) NOT NULL,
        [display_order]   int NOT NULL,
        [numeric_score]   decimal(18,4) NULL,
        [is_na]           bit NOT NULL
            CONSTRAINT [DF_response_option_is_na] DEFAULT (0),
        [active]          bit NOT NULL
            CONSTRAINT [DF_response_option_active] DEFAULT (1),
        [created_at]      datetime2(3) NOT NULL
            CONSTRAINT [DF_response_option_created] DEFAULT (SYSUTCDATETIME()),
        [updated_at]      datetime2(3) NOT NULL
            CONSTRAINT [DF_response_option_updated] DEFAULT (SYSUTCDATETIME()),
        [row_version]     rowversion NOT NULL,

        CONSTRAINT [PK_response_option]
            PRIMARY KEY CLUSTERED ([option_id]),
        CONSTRAINT [UQ_response_option_set_key]
            UNIQUE ([response_set_id], [option_key]),
        CONSTRAINT [UQ_response_option_set_code]
            UNIQUE ([response_set_id], [stored_code]),
        CONSTRAINT [FK_response_option_set]
            FOREIGN KEY ([response_set_id]) REFERENCES [icf].[response_set] ([response_set_id]),
        CONSTRAINT [CK_response_option_order]
            CHECK ([display_order] >= 0),
        CONSTRAINT [CK_response_option_key_not_blank]
            CHECK (LEN(LTRIM(RTRIM([option_key]))) > 0),
        CONSTRAINT [CK_response_option_code_not_blank]
            CHECK (LEN(LTRIM(RTRIM([stored_code]))) > 0)
    );

    CREATE TABLE [icf].[rule_definition]
    (
        [rule_id]          uniqueidentifier NOT NULL
            CONSTRAINT [DF_rule_definition_id] DEFAULT (NEWSEQUENTIALID()),
        [version_id]       uniqueidentifier NOT NULL,
        [rule_key]         nvarchar(100) NOT NULL,
        [target_type]      nvarchar(20) NOT NULL,
        [target_key]       nvarchar(100) NOT NULL,
        [effect]           nvarchar(20) NOT NULL,
        [conditions_json]  nvarchar(max) NOT NULL,
        [active]           bit NOT NULL
            CONSTRAINT [DF_rule_definition_active] DEFAULT (1),
        [created_at]       datetime2(3) NOT NULL
            CONSTRAINT [DF_rule_definition_created] DEFAULT (SYSUTCDATETIME()),
        [updated_at]       datetime2(3) NOT NULL
            CONSTRAINT [DF_rule_definition_updated] DEFAULT (SYSUTCDATETIME()),
        [row_version]      rowversion NOT NULL,

        CONSTRAINT [PK_rule_definition]
            PRIMARY KEY CLUSTERED ([rule_id]),
        CONSTRAINT [UQ_rule_version_key]
            UNIQUE ([version_id], [rule_key]),
        CONSTRAINT [FK_rule_version]
            FOREIGN KEY ([version_id]) REFERENCES [icf].[instrument_version] ([version_id]),
        CONSTRAINT [CK_rule_target_type]
            CHECK ([target_type] IN (N'SECTION', N'ITEM', N'DIMENSION')),
        CONSTRAINT [CK_rule_effect]
            CHECK ([effect] IN (N'SHOW', N'HIDE', N'REQUIRE', N'OPTIONAL')),
        CONSTRAINT [CK_rule_conditions_json]
            CHECK (ISJSON([conditions_json]) = 1),
        CONSTRAINT [CK_rule_key_not_blank]
            CHECK (LEN(LTRIM(RTRIM([rule_key]))) > 0),
        CONSTRAINT [CK_rule_target_not_blank]
            CHECK (LEN(LTRIM(RTRIM([target_key]))) > 0)
    );

    /* ================================================================
       REPORTABLE VARIABLES
       ================================================================ */

    CREATE TABLE [icf].[dimension_definition]
    (
        [dimension_id]    uniqueidentifier NOT NULL
            CONSTRAINT [DF_dimension_definition_id] DEFAULT (NEWSEQUENTIALID()),
        [code]            nvarchar(100) NOT NULL,
        [label]           nvarchar(200) NOT NULL,
        [data_type]       nvarchar(20) NOT NULL,
        [reportable]      bit NOT NULL
            CONSTRAINT [DF_dimension_reportable] DEFAULT (1),
        [sensitive]       bit NOT NULL
            CONSTRAINT [DF_dimension_sensitive] DEFAULT (0),
        [settings_json]   nvarchar(max) NULL,
        [active]          bit NOT NULL
            CONSTRAINT [DF_dimension_active] DEFAULT (1),
        [created_at]      datetime2(3) NOT NULL
            CONSTRAINT [DF_dimension_created] DEFAULT (SYSUTCDATETIME()),
        [updated_at]      datetime2(3) NOT NULL
            CONSTRAINT [DF_dimension_updated] DEFAULT (SYSUTCDATETIME()),
        [row_version]     rowversion NOT NULL,

        CONSTRAINT [PK_dimension_definition]
            PRIMARY KEY CLUSTERED ([dimension_id]),
        CONSTRAINT [UQ_dimension_definition_code]
            UNIQUE ([code]),
        CONSTRAINT [CK_dimension_data_type]
            CHECK ([data_type] IN (N'LIST', N'TEXT', N'NUMBER', N'DATE', N'BOOLEAN')),
        CONSTRAINT [CK_dimension_code_not_blank]
            CHECK (LEN(LTRIM(RTRIM([code]))) > 0),
        CONSTRAINT [CK_dimension_settings_json]
            CHECK ([settings_json] IS NULL OR ISJSON([settings_json]) = 1)
    );

    CREATE TABLE [icf].[dimension_value]
    (
        [value_id]         uniqueidentifier NOT NULL
            CONSTRAINT [DF_dimension_value_id] DEFAULT (NEWSEQUENTIALID()),
        [dimension_id]     uniqueidentifier NOT NULL,
        [value_code]       nvarchar(100) NOT NULL,
        [label]            nvarchar(300) NOT NULL,
        [display_order]    int NOT NULL,
        [effective_start]  datetime2(3) NULL,
        [effective_end]    datetime2(3) NULL,
        [active]           bit NOT NULL
            CONSTRAINT [DF_dimension_value_active] DEFAULT (1),
        [created_at]       datetime2(3) NOT NULL
            CONSTRAINT [DF_dimension_value_created] DEFAULT (SYSUTCDATETIME()),
        [updated_at]       datetime2(3) NOT NULL
            CONSTRAINT [DF_dimension_value_updated] DEFAULT (SYSUTCDATETIME()),
        [row_version]      rowversion NOT NULL,

        CONSTRAINT [PK_dimension_value]
            PRIMARY KEY CLUSTERED ([value_id]),
        CONSTRAINT [UQ_dimension_value_id_dimension]
            UNIQUE ([value_id], [dimension_id]),
        CONSTRAINT [UQ_dimension_value_code]
            UNIQUE ([dimension_id], [value_code]),
        CONSTRAINT [FK_dimension_value_definition]
            FOREIGN KEY ([dimension_id]) REFERENCES [icf].[dimension_definition] ([dimension_id]),
        CONSTRAINT [CK_dimension_value_order]
            CHECK ([display_order] >= 0),
        CONSTRAINT [CK_dimension_value_dates]
            CHECK ([effective_end] IS NULL OR [effective_start] IS NULL OR [effective_end] > [effective_start]),
        CONSTRAINT [CK_dimension_value_code_not_blank]
            CHECK (LEN(LTRIM(RTRIM([value_code]))) > 0)
    );

    CREATE TABLE [icf].[instrument_dimension]
    (
        [version_id]      uniqueidentifier NOT NULL,
        [dimension_id]    uniqueidentifier NOT NULL,
        [section_id]      uniqueidentifier NULL,
        [display_order]   int NOT NULL,
        [required]        bit NOT NULL
            CONSTRAINT [DF_instrument_dimension_required] DEFAULT (0),
        [rule_key]        nvarchar(100) NULL,
        [label_override]  nvarchar(200) NULL,
        [settings_json]   nvarchar(max) NULL,
        [created_at]      datetime2(3) NOT NULL
            CONSTRAINT [DF_instrument_dimension_created] DEFAULT (SYSUTCDATETIME()),
        [updated_at]      datetime2(3) NOT NULL
            CONSTRAINT [DF_instrument_dimension_updated] DEFAULT (SYSUTCDATETIME()),
        [row_version]     rowversion NOT NULL,

        CONSTRAINT [PK_instrument_dimension]
            PRIMARY KEY CLUSTERED ([version_id], [dimension_id]),
        CONSTRAINT [FK_instrument_dimension_version]
            FOREIGN KEY ([version_id]) REFERENCES [icf].[instrument_version] ([version_id]),
        CONSTRAINT [FK_instrument_dimension_definition]
            FOREIGN KEY ([dimension_id]) REFERENCES [icf].[dimension_definition] ([dimension_id]),
        CONSTRAINT [FK_instrument_dimension_section]
            FOREIGN KEY ([section_id], [version_id])
            REFERENCES [icf].[section_definition] ([section_id], [version_id]),
        CONSTRAINT [FK_instrument_dimension_rule]
            FOREIGN KEY ([version_id], [rule_key])
            REFERENCES [icf].[rule_definition] ([version_id], [rule_key]),
        CONSTRAINT [CK_instrument_dimension_order]
            CHECK ([display_order] >= 0),
        CONSTRAINT [CK_instrument_dimension_settings_json]
            CHECK ([settings_json] IS NULL OR ISJSON([settings_json]) = 1)
    );

    CREATE TABLE [icf].[item_definition]
    (
        [item_id]          uniqueidentifier NOT NULL
            CONSTRAINT [DF_item_definition_id] DEFAULT (NEWSEQUENTIALID()),
        [version_id]       uniqueidentifier NOT NULL,
        [section_id]       uniqueidentifier NOT NULL,
        [response_set_id]  uniqueidentifier NULL,
        [item_key]         nvarchar(100) NOT NULL,
        [reporting_key]    nvarchar(100) NULL,
        [item_type]        nvarchar(40) NOT NULL,
        [prompt]           nvarchar(max) NOT NULL,
        [help_text]        nvarchar(max) NULL,
        [display_order]    int NOT NULL,
        [required]         bit NOT NULL
            CONSTRAINT [DF_item_definition_required] DEFAULT (0),
        [settings_json]    nvarchar(max) NULL,
        [active]           bit NOT NULL
            CONSTRAINT [DF_item_definition_active] DEFAULT (1),
        [created_at]       datetime2(3) NOT NULL
            CONSTRAINT [DF_item_definition_created] DEFAULT (SYSUTCDATETIME()),
        [updated_at]       datetime2(3) NOT NULL
            CONSTRAINT [DF_item_definition_updated] DEFAULT (SYSUTCDATETIME()),
        [row_version]      rowversion NOT NULL,

        CONSTRAINT [PK_item_definition]
            PRIMARY KEY CLUSTERED ([item_id]),
        CONSTRAINT [UQ_item_id_version]
            UNIQUE ([item_id], [version_id]),
        CONSTRAINT [UQ_item_version_key]
            UNIQUE ([version_id], [item_key]),
        CONSTRAINT [FK_item_version]
            FOREIGN KEY ([version_id]) REFERENCES [icf].[instrument_version] ([version_id]),
        CONSTRAINT [FK_item_section_same_version]
            FOREIGN KEY ([section_id], [version_id])
            REFERENCES [icf].[section_definition] ([section_id], [version_id]),
        CONSTRAINT [FK_item_response_set_same_version]
            FOREIGN KEY ([response_set_id], [version_id])
            REFERENCES [icf].[response_set] ([response_set_id], [version_id]),
        CONSTRAINT [CK_item_order]
            CHECK ([display_order] >= 0),
        CONSTRAINT [CK_item_key_not_blank]
            CHECK (LEN(LTRIM(RTRIM([item_key]))) > 0),
        CONSTRAINT [CK_item_type_not_blank]
            CHECK (LEN(LTRIM(RTRIM([item_type]))) > 0),
        CONSTRAINT [CK_item_prompt_not_blank]
            CHECK (LEN(LTRIM(RTRIM([prompt]))) > 0),
        CONSTRAINT [CK_item_settings_json]
            CHECK ([settings_json] IS NULL OR ISJSON([settings_json]) = 1)
    );

    /* ================================================================
       WALKS AND RESPONSES
       ================================================================ */

    CREATE TABLE [icf].[walk]
    (
        [walk_id]                 uniqueidentifier NOT NULL
            CONSTRAINT [DF_walk_id] DEFAULT (NEWSEQUENTIALID()),
        [version_id]              uniqueidentifier NOT NULL,
        [org_unit_id]             uniqueidentifier NOT NULL,
        [owner_user_id]           uniqueidentifier NOT NULL,
        [teacher_identifier]      nvarchar(100) NULL,
        [teacher_display_name]    nvarchar(200) NULL,
        [teacher_email]           nvarchar(320) NULL,
        [classroom_label]         nvarchar(100) NULL,
        [status]                  nvarchar(20) NOT NULL
            CONSTRAINT [DF_walk_status] DEFAULT (N'DRAFT'),
        [observed_at]             datetime2(3) NOT NULL
            CONSTRAINT [DF_walk_observed] DEFAULT (SYSUTCDATETIME()),
        [created_at]              datetime2(3) NOT NULL
            CONSTRAINT [DF_walk_created] DEFAULT (SYSUTCDATETIME()),
        [updated_at]              datetime2(3) NOT NULL
            CONSTRAINT [DF_walk_updated] DEFAULT (SYSUTCDATETIME()),
        [completed_at]            datetime2(3) NULL,
        [voided_at]               datetime2(3) NULL,
        [void_reason]             nvarchar(1000) NULL,
        [row_version]             rowversion NOT NULL,

        CONSTRAINT [PK_walk]
            PRIMARY KEY CLUSTERED ([walk_id]),
        CONSTRAINT [UQ_walk_id_version]
            UNIQUE ([walk_id], [version_id]),
        CONSTRAINT [FK_walk_version]
            FOREIGN KEY ([version_id]) REFERENCES [icf].[instrument_version] ([version_id]),
        CONSTRAINT [FK_walk_org_unit]
            FOREIGN KEY ([org_unit_id]) REFERENCES [icf].[org_unit] ([org_unit_id]),
        CONSTRAINT [FK_walk_owner]
            FOREIGN KEY ([owner_user_id]) REFERENCES [icf].[app_user] ([user_id]),
        CONSTRAINT [CK_walk_status]
            CHECK ([status] IN (N'DRAFT', N'COMPLETED', N'VOIDED')),
        CONSTRAINT [CK_walk_completion]
            CHECK
            (
                ([status] = N'DRAFT' AND [completed_at] IS NULL AND [voided_at] IS NULL)
                OR ([status] = N'COMPLETED' AND [completed_at] IS NOT NULL AND [voided_at] IS NULL)
                OR ([status] = N'VOIDED' AND [voided_at] IS NOT NULL)
            )
    );

    CREATE TABLE [icf].[walk_dimension_value]
    (
        [walk_id]            uniqueidentifier NOT NULL,
        [version_id]         uniqueidentifier NOT NULL,
        [dimension_id]       uniqueidentifier NOT NULL,
        [selected_value_id]  uniqueidentifier NULL,
        [text_value]         nvarchar(1000) NULL,
        [number_value]       decimal(18,4) NULL,
        [date_value]         date NULL,
        [boolean_value]      bit NULL,
        [created_at]         datetime2(3) NOT NULL
            CONSTRAINT [DF_walk_dimension_created] DEFAULT (SYSUTCDATETIME()),
        [updated_at]         datetime2(3) NOT NULL
            CONSTRAINT [DF_walk_dimension_updated] DEFAULT (SYSUTCDATETIME()),
        [row_version]        rowversion NOT NULL,

        CONSTRAINT [PK_walk_dimension_value]
            PRIMARY KEY CLUSTERED ([walk_id], [dimension_id]),
        CONSTRAINT [FK_walk_dimension_walk_version]
            FOREIGN KEY ([walk_id], [version_id])
            REFERENCES [icf].[walk] ([walk_id], [version_id]),
        CONSTRAINT [FK_walk_dimension_instrument_dimension]
            FOREIGN KEY ([version_id], [dimension_id])
            REFERENCES [icf].[instrument_dimension] ([version_id], [dimension_id]),
        CONSTRAINT [FK_walk_dimension_selected_value]
            FOREIGN KEY ([selected_value_id], [dimension_id])
            REFERENCES [icf].[dimension_value] ([value_id], [dimension_id]),
        CONSTRAINT [CK_walk_dimension_has_value]
            CHECK
            (
                [selected_value_id] IS NOT NULL
                OR [text_value] IS NOT NULL
                OR [number_value] IS NOT NULL
                OR [date_value] IS NOT NULL
                OR [boolean_value] IS NOT NULL
            )
    );

    CREATE TABLE [icf].[walk_response]
    (
        [response_id]        uniqueidentifier NOT NULL
            CONSTRAINT [DF_walk_response_id] DEFAULT (NEWSEQUENTIALID()),
        [walk_id]            uniqueidentifier NOT NULL,
        [version_id]         uniqueidentifier NOT NULL,
        [item_id]            uniqueidentifier NOT NULL,
        [response_state]     nvarchar(30) NOT NULL
            CONSTRAINT [DF_walk_response_state] DEFAULT (N'UNANSWERED'),
        [selected_option_id] uniqueidentifier NULL,
        [text_value]         nvarchar(max) NULL,
        [number_value]       decimal(18,4) NULL,
        [date_value]         date NULL,
        [boolean_value]      bit NULL,
        [created_at]         datetime2(3) NOT NULL
            CONSTRAINT [DF_walk_response_created] DEFAULT (SYSUTCDATETIME()),
        [updated_at]         datetime2(3) NOT NULL
            CONSTRAINT [DF_walk_response_updated] DEFAULT (SYSUTCDATETIME()),
        [row_version]        rowversion NOT NULL,

        CONSTRAINT [PK_walk_response]
            PRIMARY KEY CLUSTERED ([response_id]),
        CONSTRAINT [UQ_walk_response_walk_item]
            UNIQUE ([walk_id], [item_id]),
        CONSTRAINT [FK_walk_response_walk_version]
            FOREIGN KEY ([walk_id], [version_id])
            REFERENCES [icf].[walk] ([walk_id], [version_id]),
        CONSTRAINT [FK_walk_response_item_version]
            FOREIGN KEY ([item_id], [version_id])
            REFERENCES [icf].[item_definition] ([item_id], [version_id]),
        CONSTRAINT [FK_walk_response_selected_option]
            FOREIGN KEY ([selected_option_id]) REFERENCES [icf].[response_option] ([option_id]),
        CONSTRAINT [CK_walk_response_state]
            CHECK ([response_state] IN
                (N'UNANSWERED', N'ANSWERED', N'HIDDEN', N'NOT_APPLICABLE'))
    );

    CREATE TABLE [icf].[walk_response_selection]
    (
        [response_id]  uniqueidentifier NOT NULL,
        [option_id]    uniqueidentifier NOT NULL,
        [selected_at]  datetime2(3) NOT NULL
            CONSTRAINT [DF_walk_selection_selected] DEFAULT (SYSUTCDATETIME()),

        CONSTRAINT [PK_walk_response_selection]
            PRIMARY KEY CLUSTERED ([response_id], [option_id]),
        CONSTRAINT [FK_walk_selection_response]
            FOREIGN KEY ([response_id]) REFERENCES [icf].[walk_response] ([response_id]),
        CONSTRAINT [FK_walk_selection_option]
            FOREIGN KEY ([option_id]) REFERENCES [icf].[response_option] ([option_id])
    );

    /* ================================================================
       REVISION AND AUDIT HISTORY
       ================================================================ */

    CREATE TABLE [icf].[walk_revision]
    (
        [revision_id]          uniqueidentifier NOT NULL
            CONSTRAINT [DF_walk_revision_id] DEFAULT (NEWSEQUENTIALID()),
        [walk_id]              uniqueidentifier NOT NULL,
        [revision_number]      int NOT NULL,
        [actor_user_id]        uniqueidentifier NOT NULL,
        [reason]               nvarchar(1000) NOT NULL,
        [prior_snapshot_json]  nvarchar(max) NOT NULL,
        [created_at]           datetime2(3) NOT NULL
            CONSTRAINT [DF_walk_revision_created] DEFAULT (SYSUTCDATETIME()),

        CONSTRAINT [PK_walk_revision]
            PRIMARY KEY CLUSTERED ([revision_id]),
        CONSTRAINT [UQ_walk_revision_number]
            UNIQUE ([walk_id], [revision_number]),
        CONSTRAINT [FK_walk_revision_walk]
            FOREIGN KEY ([walk_id]) REFERENCES [icf].[walk] ([walk_id]),
        CONSTRAINT [FK_walk_revision_actor]
            FOREIGN KEY ([actor_user_id]) REFERENCES [icf].[app_user] ([user_id]),
        CONSTRAINT [CK_walk_revision_number]
            CHECK ([revision_number] > 0),
        CONSTRAINT [CK_walk_revision_reason_not_blank]
            CHECK (LEN(LTRIM(RTRIM([reason]))) > 0),
        CONSTRAINT [CK_walk_revision_snapshot_json]
            CHECK (ISJSON([prior_snapshot_json]) = 1)
    );

    CREATE TABLE [icf].[audit_event]
    (
        [event_id]          bigint IDENTITY(1,1) NOT NULL,
        [entity_type]       nvarchar(60) NOT NULL,
        [entity_id]         uniqueidentifier NULL,
        [event_type]        nvarchar(80) NOT NULL,
        [actor_user_id]     uniqueidentifier NULL,
        [event_at]          datetime2(3) NOT NULL
            CONSTRAINT [DF_audit_event_at] DEFAULT (SYSUTCDATETIME()),
        [correlation_id]    uniqueidentifier NULL,
        [details_json]      nvarchar(max) NULL,

        CONSTRAINT [PK_audit_event]
            PRIMARY KEY CLUSTERED ([event_id]),
        CONSTRAINT [FK_audit_event_actor]
            FOREIGN KEY ([actor_user_id]) REFERENCES [icf].[app_user] ([user_id]),
        CONSTRAINT [CK_audit_entity_type_not_blank]
            CHECK (LEN(LTRIM(RTRIM([entity_type]))) > 0),
        CONSTRAINT [CK_audit_event_type_not_blank]
            CHECK (LEN(LTRIM(RTRIM([event_type]))) > 0),
        CONSTRAINT [CK_audit_details_json]
            CHECK ([details_json] IS NULL OR ISJSON([details_json]) = 1)
    );

    /* ================================================================
       INDEXES FOR AUTHORIZATION, AUTOSAVE, AND TREND REPORTING
       ================================================================ */

    CREATE INDEX [IX_org_unit_parent_active]
        ON [icf].[org_unit] ([parent_org_unit_id], [active])
        INCLUDE ([org_unit_code], [org_unit_type], [name]);

    CREATE INDEX [IX_user_role_scope_user_dates]
        ON [icf].[user_role_scope] ([user_id], [effective_start], [effective_end])
        INCLUDE ([role_id], [org_unit_id], [include_descendants]);

    CREATE INDEX [IX_user_role_scope_org_dates]
        ON [icf].[user_role_scope] ([org_unit_id], [effective_start], [effective_end])
        INCLUDE ([user_id], [role_id], [include_descendants]);

    CREATE INDEX [IX_instrument_version_status_dates]
        ON [icf].[instrument_version] ([instrument_id], [status], [effective_start], [effective_end]);

    CREATE UNIQUE INDEX [UX_section_sibling_order]
        ON [icf].[section_definition] ([version_id], [parent_section_id], [display_order]);

    CREATE INDEX [IX_section_version_order]
        ON [icf].[section_definition] ([version_id], [display_order])
        INCLUDE ([parent_section_id], [section_key], [title], [active]);

    CREATE UNIQUE INDEX [UX_response_option_order]
        ON [icf].[response_option] ([response_set_id], [display_order]);

    CREATE INDEX [IX_response_option_set_active]
        ON [icf].[response_option] ([response_set_id], [active], [display_order])
        INCLUDE ([stored_code], [label], [numeric_score], [is_na]);

    CREATE UNIQUE INDEX [UX_dimension_value_order]
        ON [icf].[dimension_value] ([dimension_id], [display_order]);

    CREATE INDEX [IX_dimension_value_active_dates]
        ON [icf].[dimension_value]
            ([dimension_id], [active], [effective_start], [effective_end], [display_order])
        INCLUDE ([value_code], [label]);

    CREATE UNIQUE INDEX [UX_instrument_dimension_order]
        ON [icf].[instrument_dimension] ([version_id], [display_order]);

    CREATE UNIQUE INDEX [UX_item_section_order]
        ON [icf].[item_definition] ([version_id], [section_id], [display_order]);

    CREATE INDEX [IX_item_reporting_key]
        ON [icf].[item_definition] ([reporting_key], [version_id])
        INCLUDE ([item_id], [section_id], [item_type], [active])
        WHERE [reporting_key] IS NOT NULL;

    CREATE INDEX [IX_walk_org_observed]
        ON [icf].[walk] ([org_unit_id], [observed_at], [status])
        INCLUDE ([walk_id], [version_id], [owner_user_id], [completed_at]);

    CREATE INDEX [IX_walk_owner_status_updated]
        ON [icf].[walk] ([owner_user_id], [status], [updated_at])
        INCLUDE ([walk_id], [version_id], [org_unit_id], [observed_at]);

    CREATE INDEX [IX_walk_dimension_report]
        ON [icf].[walk_dimension_value] ([dimension_id], [selected_value_id])
        INCLUDE ([walk_id], [version_id], [number_value], [date_value], [boolean_value]);

    CREATE INDEX [IX_walk_response_walk]
        ON [icf].[walk_response] ([walk_id])
        INCLUDE ([item_id], [response_state], [selected_option_id]);

    CREATE INDEX [IX_walk_response_report]
        ON [icf].[walk_response] ([item_id], [selected_option_id], [response_state])
        INCLUDE ([walk_id], [version_id], [number_value], [date_value], [boolean_value]);

    CREATE INDEX [IX_walk_selection_option]
        ON [icf].[walk_response_selection] ([option_id])
        INCLUDE ([response_id]);

    CREATE INDEX [IX_walk_revision_walk_created]
        ON [icf].[walk_revision] ([walk_id], [created_at])
        INCLUDE ([revision_number], [actor_user_id]);

    CREATE INDEX [IX_audit_entity_time]
        ON [icf].[audit_event] ([entity_type], [entity_id], [event_at]);

    CREATE INDEX [IX_audit_actor_time]
        ON [icf].[audit_event] ([actor_user_id], [event_at])
        WHERE [actor_user_id] IS NOT NULL;

    /* ================================================================
       INITIAL REFERENCE DATA
       The master role is deliberately separate from walk and report access.
       ================================================================ */

    INSERT INTO [icf].[app_role]
    (
        [role_code],
        [name],
        [description],
        [scope_type],
        [can_create_walk],
        [can_open_walk_details],
        [can_edit_owned_walks],
        [can_view_aggregate_reports],
        [can_manage_instruments]
    )
    VALUES
        (N'DISTRICT_WALK_REPORT',
         N'District Walk and Reports',
         N'Conduct walks, open completed walk details in scope, edit owned walks, and view district and school aggregate reports.',
         N'DISTRICT', 1, 1, 1, 1, 0),

        (N'DISTRICT_REPORT_ONLY',
         N'District Reports Only',
         N'View district and school aggregate reports without access to individual walk details.',
         N'DISTRICT', 0, 0, 0, 1, 0),

        (N'SCHOOL_WALK_REPORT',
         N'School Walk and Reports',
         N'Conduct walks, open completed walk details in assigned schools, edit owned walks, and view aggregate reports for assigned schools.',
         N'SCHOOL', 1, 1, 1, 1, 0),

        (N'SCHOOL_REPORT_ONLY',
         N'School Reports Only',
         N'View aggregate reports for assigned schools without access to individual walk details.',
         N'SCHOOL', 0, 0, 0, 1, 0),

        (N'MASTER_INSTRUMENT_ADMIN',
         N'Master Instrument Administrator',
         N'Create, validate, preview, publish, and retire instrument versions. Walk and report access require a separate role.',
         N'GLOBAL', 0, 0, 0, 0, 1);

    INSERT INTO [icf].[instrument]
    (
        [code],
        [name],
        [description]
    )
    VALUES
    (
        N'ICFWALK',
        N'ICFWalk',
        N'Instructional walkthrough instrument migrated from the original ICFWalk application.'
    );

    COMMIT TRANSACTION;

    SELECT
        N'ICFWalk database objects created successfully.' AS [result],
        COUNT_BIG(*) AS [table_count]
    FROM sys.tables
    WHERE schema_id = SCHEMA_ID(N'icf');
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;

