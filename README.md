# Rowset

A macOS database browser for Postgres, with AWS IAM sign-in.

Pick a saved connection, read a table, filter and sort it, change a value, and run SQL. Rowset
signs in to an RDS instance with an IAM token that it fetches at every connect, or to any other
server with a user and a password.

## What it does

- Saves connections as bookmarks. The bookmark file holds no secret.
- Signs in with AWS IAM or with a user and a password.
- Shows schemas, tables, views, and columns in a tree on the left.
- Opens a table in a tab, with a `WHERE` field, sortable columns, and pages.
- Shows the whole value of a cell in a pane under the grid. It formats JSON and colours it.
- Copies a value, a column name, or a block of cells, in the formats a spreadsheet reads.
- Changes a value and sends the edits together, after it shows you the SQL.
- Runs SQL in a console, one statement at a time or all of them.

Rowset speaks Postgres. The driver sits behind a protocol, so another one can join it.

## Install

Download the DMG from the [latest release](../../releases/latest) and drag Rowset to
`/Applications`.

The app is not signed. On the first launch, right click it and pick **Open**, then confirm.

## Requirements

- macOS 14.4 or later.
- For AWS IAM: the AWS CLI version 2 and a working SSO profile in `~/.aws/config`.

## Add a connection

1. Press the `+` button under the sidebar.
2. Fill in the host, the port, the database, and the database user.
3. Pick the sign-in method, and the AWS profile for IAM. Rowset reads the profile names from
   `~/.aws/config`.
4. Press **Test Connection**, then **Save**.

The database user is the IAM database user, for example `cube_testing_iam_owner`. It is not your
AWS user name.

## Signing in

**AWS IAM.** Rowset never signs a request itself. At every connect it runs
`aws rds generate-db-auth-token`, and the AWS CLI handles the SSO token cache, the refresh, and
any role chaining. The token it returns is the connection password, and it lasts 15 minutes. If
the SSO session expired, Rowset shows a sheet with the login command and a button that runs it.

**A user and a password.** The password goes into your login keychain under the id of the
bookmark, and it leaves when you delete the bookmark. Pick this for a server that has no IAM.

RDS IAM needs an encrypted connection. Each bookmark picks **verify-full**, which checks the
server against the bundled AWS RDS root store, **require**, which encrypts without checking the
server, or **disable**.

## Keys

| Key | What it does |
| --- | --- |
| Arrows, or `h` `j` `k` `l` | move the picked cell. Shift grows the block |
| Return | change the picked cell |
| Shift-Return | open the value pane on it |
| Space | read the whole row |
| Delete | set the picked cells to NULL |
| Command-C | copy the block |
| Command-R | fetch the page again |
| Command-F | the sidebar filter, while the keyboard is in the sidebar |
| Command-T | a new console |
| Command-Return | run the statement the caret is in |
| Shift-Command-Return | run every statement, one after the other |
| Command-W | close the tab |
| Control-Tab | the next tab |
| Control-Command-S | show or hide the sidebar |

## The console

A console belongs to a connection, not to a table, and each connection keeps its own list of
saved consoles. A console takes its name from its first line, so there is no rename.

A statement needs no closing semicolon. An empty line ends one as well, so two statements written
under each other run on their own.

A statement that reads is paged, so the page widget works there as well. A statement that writes
runs as it stands.

## Large values

A column of JSON documents or arrays is what makes a wide table slow to open, because reading one
such value costs far more than sending its text. Rowset asks the server for the size of such a
column and reads the values the page can afford.

A value left on the server shows a grey stand-in naming its size, such as `9.6 kB`. It arrives
whole the moment you touch it, so a stand-in is never what you read, edit or copy.

## Changing a value

Double click a cell, or press Return on it. Change as many cells as you like, then press
**Submit**: a sheet shows the exact SQL, and nothing reaches the server before you press **Run**.
The statements share one transaction, and any statement that does not match exactly one row rolls
the whole batch back.

A table without a primary key cannot be edited, because an UPDATE needs a WHERE that finds one
row.

## Where the settings live

| Item | Location |
| --- | --- |
| Bookmarks | `~/Library/Application Support/Rowset/bookmarks.json` |
| Session | `~/Library/Application Support/Rowset/session.json` |
| Saved consoles | `~/Library/Application Support/Rowset/consoles.json` |
| Passwords | The login keychain, service `tech.alcemy.Rowset` |
| Window frame | `UserDefaults` for `tech.alcemy.Rowset` |

The bookmark file is plain JSON. You can edit it by hand and copy it to another machine.

## Build

```sh
./Scripts/bootstrap.sh
open Rowset.xcodeproj
```

The script installs XcodeGen if it is missing, downloads the RDS certificate bundle if it is
missing, and writes the Xcode project. `Rowset.xcodeproj` is not in git, and `project.yml`
describes it.

A tag that starts with `v` builds a release. The workflow in `.github/workflows/release.yml`
generates the project, runs the tests, builds, and attaches a DMG to the release.

The app icon is drawn in code. Run `./Scripts/make-icon.sh` after a change to it. The icns is
committed, so a normal build needs no extra step.

## Test

```sh
xcodebuild -project Rowset.xcodeproj -scheme Rowset -destination 'platform=macOS' test
```

The unit tests need no database.

### Live tests

`LiveConnectionTests` talks to a real database, and skips itself when the environment does not
describe one:

```sh
ROWSET_LIVE_HOST=name.eu-central-1.rds.amazonaws.com \
ROWSET_LIVE_DB=cube_testing \
ROWSET_LIVE_USER=cube_testing_iam_owner \
ROWSET_LIVE_PROFILE=AlcemyElevatedAccess-211125624762 \
./Scripts/live-test.sh
```

Name a table as well, and two more suites run on it. `MeasureTests` times the shapes of the page
query, and `LiveGridTests` opens the table through the app itself:

```sh
ROWSET_MEASURE_TABLE=truck_data ROWSET_MEASURE_LIMIT=50 ./Scripts/live-test.sh
```
