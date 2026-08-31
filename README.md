# Rowset

A small macOS database browser for AWS RDS Postgres with IAM authentication.

Rowset replaces the part of a JetBrains IDE that most people use every day: pick a saved
connection, look at the tables, and read the first rows with a filter and a sort.

## What it does

- Saves connections as bookmarks. No password is stored, because none exists.
- Gets the connection password from `aws rds generate-db-auth-token` at every connect.
- Shows schemas, tables, views, and columns in a tree on the left.
- Opens a table in a tab. Each tab has a `WHERE` field, a row limit, and sortable columns.
- Runs a free-form statement in a query tab.
- Remembers the window size and position.

Postgres is the only driver for now. SQLite comes later.

## Requirements

- macOS 14.4 or later.
- Xcode 16 or later.
- The AWS CLI version 2, at `/opt/homebrew/bin/aws` or another standard location.
- A working AWS SSO profile in `~/.aws/config`.

## Build

```sh
./Scripts/bootstrap.sh
open Rowset.xcodeproj
```

The script installs XcodeGen if it is missing, downloads the RDS certificate bundle if it is
missing, and generates the Xcode project. To generate the project alone, run `xcodegen generate`.

`Rowset.xcodeproj` is not in git. `project.yml` describes it.

## Add a connection

1. Press the `+` button under the sidebar.
2. Fill in the host, the port, the database, and the database user.
3. Pick the AWS profile. Rowset reads the names from `~/.aws/config`.
4. Press **Test Connection**.
5. Press **Save**.

The database user is the IAM database user, for example `cube_testing_iam_owner`. It is not your
AWS user name.

## Authentication

Rowset never signs a request itself. At every connect it runs:

```
aws rds generate-db-auth-token \
    --hostname <host> --port <port> --username <user> \
    --region <region> --profile <profile>
```

The AWS CLI handles the SSO token cache, the refresh, and any role chaining. The result is the
connection password. It is valid for 15 minutes, so Rowset asks for a new one every time it
opens a connection.

If the SSO session expired, Rowset shows a sheet with the login command and a button that runs
it. You can also run this yourself:

```sh
aws sso login --profile <profile>
```

## Encryption

RDS IAM authentication needs an encrypted connection. Each bookmark picks one of two modes:

- **verify-full** (default) checks the server certificate against the AWS RDS root bundle in
  `Sources/Rowset/Resources/rds-global-bundle.pem`.
- **require** encrypts the connection but does not check the server identity. Use this only when
  verify-full fails and you know why.

To update the certificate bundle, run `./Scripts/fetch-rds-ca.sh`.

## Where the settings live

| Item | Location |
| --- | --- |
| Bookmarks | `~/Library/Application Support/Rowset/bookmarks.json` |
| Window frame and row limit | `UserDefaults` for `tech.alcemy.Rowset` |

The bookmark file is plain JSON. You can edit it by hand and copy it to another machine.

## Design notes

**One connection per bookmark.** Rowset uses `PostgresConnection` and not `PostgresClient`. A
client pools connections and holds one fixed password. An IAM token expires after 15 minutes, so
a pooled connection that opens later would carry a dead token.

**The app decodes every column type itself.** Postgres sends most values in a binary format.
`CellRenderer` turns each type into text. It decodes the date and time types by hand, because a
`Date` loses part of the microsecond precision that Postgres sends.

**Sorting happens on the server.** A click on a column header changes the `ORDER BY` and runs the
query again. A sort inside the app would only order the rows that are already loaded.

**The app is not sandboxed.** It reads `~/.aws/config` and runs the `aws` binary.

## Test

```sh
xcodebuild -project Rowset.xcodeproj -scheme Rowset -destination 'platform=macOS' test
```

The tests cover the SQL builder, the AWS config parser, and the cell renderer. None of them
needs a database.

### Live tests

`LiveConnectionTests` talks to a real database. It skips itself when the environment does not
describe one. To run it:

```sh
ROWSET_LIVE_HOST=name.eu-central-1.rds.amazonaws.com \
ROWSET_LIVE_DB=cube_testing \
ROWSET_LIVE_USER=cube_testing_iam_owner \
ROWSET_LIVE_PROFILE=AlcemyElevatedAccess-211125624762 \
./Scripts/live-test.sh
```

The tests check the token, the TLS connect, the catalog queries, the row limit, the sort, and
that a failed statement leaves the connection open.
