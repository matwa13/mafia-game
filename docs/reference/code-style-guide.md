# DocBrief - Code Style Guide

This document defines code style requirements for Lua and YAML files in DocBrief.

## 1. Type Annotations

All Lua code MUST be fully typed. Wippy uses a **sound, gradual type system** where types are
non-nullable by default.

### 1.1 Basic Types

```lua
local n: number = 3.14
local s: string = "hello"
local b: boolean = true
local t: table = {}
```

### 1.2 Optional Types

Use `?` suffix to indicate "type or nil":

```lua
local y: number? = nil      -- OK: explicitly optional
local x: number = nil       -- ERROR: number is non-nullable

-- In function parameters
function process(name: string, description: string?)
    -- description can be nil
end
```

### 1.3 Function Signatures

All functions MUST have typed parameters and return types:

```lua
-- Single return value
local function add(a: number, b: number): number
    return a + b
end

-- Multiple return values (tuple)
local function div_mod(a: number, b: number): (number, number)
    return math.floor(a / b), a % b
end

-- Error pattern (value, error)
local function fetch_user(id: string): (User?, string?)
    -- Returns (user, nil) on success
    -- Returns (nil, "error message") on failure
end

-- Void function with optional error
local function handler(): (nil, string?)
    -- Returns nil on success
    -- Returns (nil, "error message") on failure
end
```

### 1.4 Record Types

Define named types for structured data:

```lua
type User = {
    id: string,
    email: string,
    full_name: string?,     -- Optional field
    status: string,
    created_at: string,
}

type Filters = {
    email?: string,         -- Optional field
    status?: string,
    ids?: {string},
}

type Config = {
    host: string,
    port: number,
    timeout?: number,       -- Optional with no default
}
```

### 1.5 Arrays

```lua
local ids: {string} = {"a", "b", "c"}
local numbers: {number} = {1, 2, 3}

-- Array access returns optional type
local arr: {number} = {1, 2, 3}
local x = arr[1]            -- x: number? (not number)
```

### 1.6 Union and Literal Types

```lua
type Status = "active" | "inactive" | "suspended"
type Result = string | number

-- Tagged unions for state machines
type LoadState =
    | {status: "loading"}
    | {status: "loaded", data: User}
    | {status: "error", message: string}
```

### 1.7 Generics

```lua
local function identity<T>(x: T): T
    return x
end

-- With constraints
type HasName = {name: string}
local function greet<T: HasName>(obj: T): string
    return "Hello, " .. obj.name
end
```

### 1.8 Metatable Typing

When using metatables, create the typed table **before** calling `setmetatable`:

```lua
-- CORRECT: Create typed table first, then apply metatable
function reader.new(): ReaderState
    local filters: Filters = {}
    local state: ReaderState = {
        _filters = filters,
        _limit = 50,
        _offset = 0,
        _order_by = "created_at",
        _order_dir = "DESC",
    }
    return setmetatable(state, reader_mt)
end

-- CORRECT: Clone with typed table
function reader:_clone(): ReaderState
    local filters: Filters = {}
    for k, v in pairs(self._filters) do filters[k] = v end

    local state: ReaderState = {
        _filters = filters,
        _limit = self._limit,
        _offset = self._offset,
        _order_by = self._order_by,
        _order_dir = self._order_dir,
    }
    return setmetatable(state, reader_mt)
end

-- WRONG: Empty table passed to setmetatable loses type information
function reader:_clone(): ReaderState
    local copy: ReaderState = setmetatable({}, reader_mt)  -- ERROR: {} is any
    copy._filters = {}
    return copy
end
```

### 1.9 Varargs Typing

```lua
-- Type varargs with colon syntax
function reader:with_ids(...: string): ReaderState
    local copy: ReaderState = self:_clone()
    copy._filters.ids = {...}
    return copy
end
```

### 1.10 Local Function Types

All local helper functions must be typed:

```lua
-- CORRECT
local function hash_password(password: string): (string?, string?)
    local hashed, err = hash.sha512(password)
    if err then
        return nil, "Failed to hash password: " .. err
    end
    return hashed
end

-- WRONG: missing types
local function hash_password(password)
    -- ...
end
```

## 2. Naming Conventions

### 2.1 Variables and Functions

Use `snake_case` for all identifiers:

```lua
-- CORRECT
local user_id = "123"
local organization_id = actor:meta().organization_id
local function validate_email(email: string): (boolean, string?)

-- WRONG
local userId = "123"
local organizationId = actor:meta().organizationId
local function validateEmail(email)
```

### 2.2 Constants

Use `UPPER_SNAKE_CASE` for constants:

```lua
local DB_RESOURCE = "app:db"
local TABLE_NAME = "users"
local MAX_RETRIES = 3

-- Constant tables
local consts = {
    USER_STATUS = {
        ACTIVE = "active",
        INACTIVE = "inactive",
        SUSPENDED = "suspended",
    },
    ERROR = {
        USER_NOT_FOUND = "User not found",
        INVALID_EMAIL = "Invalid email format",
    },
    LIMITS = {
        MAX_EMAIL_LENGTH = 255,
        MIN_PASSWORD_LENGTH = 8,
    },
}
```

### 2.3 Type Names

Use `PascalCase` for type definitions:

```lua
type User = { ... }
type ReaderState = { ... }
type CommandResult = { ... }
type AdminConfig = { ... }
```

### 2.4 Private Fields

Use underscore prefix for internal/private fields:

```lua
type ReaderState = {
    _filters: Filters,      -- Internal state
    _limit: number,
    _offset: number,
}

-- Internal methods
function reader:_clone(): ReaderState
function reader:_build_query(columns: {string})
```

### 2.5 Module Structure

```lua
-- 1. Requires at the top (no blank lines between them)
local sql = require("sql")
local hash = require("hash")
local consts = require("consts")
local config = require("persistence_config")

-- 2. Constants
local TABLE_NAME = "users"

-- 4. Type definitions
type Filters = { ... }
type ReaderState = { ... }

-- 5. Module table
local reader = {}
local reader_mt: metatable<ReaderState> = { __index = reader }

-- 6. Constructor
function reader.new(): ReaderState

-- 7. Public methods
function reader:with_email(email: string): ReaderState

-- 8. Private methods (underscore prefix)
function reader:_clone(): ReaderState
function reader:_build_query(columns: {string})

-- 9. Return module
return reader
```

## 3. Comments

### 3.1 When to Comment

Add comments ONLY when the code is not self-explanatory:

```lua
-- CORRECT: Comment explains WHY, not WHAT
-- Use constant-time comparison to prevent timing attacks
local is_valid = crypto.constant_time_compare(stored_hash, provided_hash)

-- CORRECT: Comment explains complex business logic
-- Admin accounts created during migration use a different validation flow
if is_default_admin then
    -- Skip email verification for bootstrap admin
end

-- WRONG: Comment states the obvious
-- Get the user by email
local user = reader.new():with_email(email):one()

-- WRONG: Comment duplicates the code
-- Set status to active
user.status = "active"
```

### 3.2 Do NOT Add Comments For

- Function parameters (use types instead)
- Return values (use return types instead)
- Variable declarations (use descriptive names)
- Obvious operations

### 3.3 TODO Comments

Use `TODO:` prefix for temporary notes:

```lua
-- TODO: Implement pagination
-- TODO: Add rate limiting
```

## 4. YAML File Formatting

### 4.1 Basic Structure

```yaml
version: "1.0"
namespace: app.domain

entries:
    - name: entry_name
      kind: library.lua
      source: file://filename.lua
```

### 4.2 Array Formatting

Arrays use YAML list style with each element on a new line starting with `-`:

```yaml
# CORRECT: Each element on new line with dash
entries:
    - name: reader
      kind: library.lua
      source: file://reader.lua
      modules:
          - sql
          - hash
          - crypto

    - name: ops
      kind: library.lua
      source: file://ops.lua
      modules:
          - sql
          - time

# WRONG: Inline array
modules: [sql, hash, crypto]

# WRONG: No blank line between entries
entries:
    - name: reader
      kind: library.lua
    - name: ops
      kind: library.lua
```

### 4.3 Indentation

Use 4 spaces for indentation (same as Lua):

```yaml
entries:
    - name: login
      kind: function.lua
      meta:
          comment: Admin Login API
          description: Authentication endpoint
          router: app:api.public
      source: file://login.lua
      imports:
          consts: app.admin:consts
          reader: app.admin.persist:reader
      method: handler
      modules:
          - http
          - security
          - json
          - time
```

### 4.4 Entry Comments

Use YAML comments to document entry IDs:

```yaml
entries:
    # app.admin:consts
    - name: consts
      kind: library.lua
      source: file://consts.lua

    # app.admin.persist:reader
    - name: reader
      kind: library.lua
      source: file://reader.lua
```

### 4.5 Meta Section

The `meta` section contains documentation and routing info:

```yaml
- name: login
  kind: function.lua
  meta:
      comment: Short description (required)
      description: Longer description (optional)
      router: app:api.public
      tags:
          - auth
          - admin
```

### 4.6 Imports vs Modules

- `imports` - Internal dependencies (other Lua libraries from registry)
- `modules` - Platform modules (http, sql, security, etc.)

```yaml
- name: create_user
  kind: function.lua
  source: file://create_user.lua
  imports:
      consts: app.admin:consts           # Registry entry
      user_ops: app.user.persist:ops     # Cross-domain import
  modules:
      - http                              # Platform module
      - security
      - json
```

### 4.7 Migration Entries

```yaml
- name: 01_create_users_table
  kind: function.lua
  meta:
      description: Create users table with indexes
      tags:
          - user
          - auth
      target_db: app:db
      timestamp: "2025-06-01T10:00:00Z"
      type: migration
  source: file://01_create_users_table.lua
  imports:
      migration: wippy.migration:migration
  method: migrate
```

### 4.8 Environment Variable Entries

```yaml
- name: database_resource
  kind: env.variable
  meta:
      comment: Database resource for admin system
      icon: tabler:database
      private: true
  default: app:db
  storage: app.env:router
  variable: APP_ADMIN_DATABASE_RESOURCE
```

## 5. Error Handling

### 5.1 Error Return Pattern

Use the `(value?, error?)` pattern:

```lua
-- Function signature
function fetch_data(id: string): (Data?, string?)

-- Usage
local data, err = fetch_data(id)
if err then
    return nil, err
end
-- Use data safely here
```

### 5.2 Error Messages

- Use constants for error messages
- Include context in error messages

```lua
-- Define in consts.lua
ERROR = {
    USER_NOT_FOUND = "User not found",
    INVALID_EMAIL = "Invalid email format",
    DB_OPERATION_FAILED = "Database operation failed",
}

-- Use with context
if not user then
    return nil, consts.ERROR.USER_NOT_FOUND
end

if db_err then
    return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. db_err
end
```

### 5.3 Early Returns

Prefer early returns for error handling:

```lua
-- CORRECT: Early returns
local function handler(): (nil, string?)
    local req = http.request()
    if not req then
        return nil, "Failed to get request"
    end

    local body, err = req:body_json()
    if err then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({ success = false, error = "Invalid JSON" })
        return
    end

    if not body.email then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({ success = false, error = "Missing email" })
        return
    end

    -- Happy path continues here
end

-- WRONG: Deeply nested conditions
local function handler()
    local req = http.request()
    if req then
        local body, err = req:body_json()
        if not err then
            if body.email then
                -- Happy path buried in nesting
            end
        end
    end
end
```

## 6. Code Organization

### 6.1 Line Length

Prefer lines under 100 characters. Break long lines at logical points:

```lua
-- CORRECT: Break at logical points
local result, err = ops.execute({
    type = ops.COMMANDS.CREATE,
    payload = {
        id = user_id,
        email = body.email,
        full_name = body.full_name,
        status = body.status or consts.DEFAULTS.USER_STATUS,
    }
})

-- CORRECT: Break method chains
local users, err = reader.new()
    :with_organization(org_id)
    :with_status("active")
    :limit(50)
    :all()
```

### 6.2 Blank Lines

Use blank lines to separate logical sections. Note: multiple `require` statements go together without blank lines between them:

```lua
local sql = require("sql")
local hash = require("hash")
local consts = require("consts")
local config = require("persistence_config")

local TABLE_NAME = "users"

type Filters = {
    email?: string,
    status?: string,
}

local reader = {}

function reader.new(): ReaderState
    -- ...
end

function reader:with_email(email: string): ReaderState
    -- ...
end
```

### 6.3 Table Formatting

```lua
-- Short tables: single line
local point = { x = 1, y = 2 }

-- Longer tables: multi-line with trailing comma
local config = {
    host = "localhost",
    port = 5432,
    timeout = 30,
}

-- Nested tables
local response = {
    success = true,
    user = {
        id = user.id,
        email = user.email,
        status = user.status,
    },
}
```

## 7. Summary Checklist

When writing or reviewing code, verify:

- [ ] All functions have typed parameters and return types
- [ ] All local variables that need types are annotated
- [ ] Optional types use `?` suffix
- [ ] Record types are defined for structured data
- [ ] Names use `snake_case` (variables/functions) or `UPPER_SNAKE_CASE` (constants)
- [ ] Type names use `PascalCase`
- [ ] Comments explain WHY, not WHAT
- [ ] No redundant comments on obvious code
- [ ] YAML arrays use list style with `-` on new lines
- [ ] YAML uses 4-space indentation
- [ ] Metatable patterns create typed tables before `setmetatable`
- [ ] Varargs are typed with `...: type` syntax
- [ ] Error handling uses early returns
- [ ] Error messages come from constants
- [ ] Multiple `require` statements have no blank lines between them
