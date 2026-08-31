# Rowset

A small macOS database browser for AWS RDS Postgres with IAM authentication.

Rowset replaces the part of a JetBrains IDE that most people use every day: pick a saved
connection, look at the tables, and read the first rows with a filter and a sort.

## What it does

- Saves connections as bookmarks. The bookmark file holds no secret.
- Signs in with AWS IAM or with a user and a password. An IAM token comes from
  `aws rds generate-db-auth-token` at every connect. A password goes into the login keychain.
- Shows schemas, tables, views, and columns in a tree on the left.
- Opens a table in a tab. Each tab has a `WHERE` field, sortable columns, and pages.
- Shows the whole value of the cell you click in a pane under the grid. It formats JSON and
  keeps the key order that the server sent.
- Copies a value, a column name, or a whole row from the right click menu of a cell.
- Changes a value and sends the edits together, after it shows you the SQL.
- Runs SQL in a console, one statement at a time or all of them, with the words coloured and the
  statement under the caret marked.
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

## The app icon

The icon is a drawing in code, not a file somebody exported:

```sh
./Scripts/make-icon.sh
```

`Scripts/make-icon.swift` draws every size, and `iconutil` builds
`Sources/Rowset/Resources/AppIcon.icns` out of them. Change a color or a proportion, run the
script again, and build. The icns is committed, so a normal build needs no extra step.

The asset catalog is not used for this. Its compiler kept only four sizes and stopped at 256
points, so `iconutil` builds the file instead. It writes all ten, up to 1024 points.

macOS caches an app icon per bundle path, so a fresh icon may not appear at once. To force it:

```sh
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/\
LaunchServices.framework/Versions/A/Support/lsregister -f <path to Rowset.app>
```

## Add a connection

1. Press the `+` button under the sidebar.
2. Fill in the host, the port, the database, and the database user.
3. Pick the AWS profile. Rowset reads the names from `~/.aws/config`.
4. Press **Test Connection**.
5. Press **Save**.

The database user is the IAM database user, for example `cube_testing_iam_owner`. It is not your
AWS user name.

## Authentication

Each bookmark picks one of two methods.

### User and password

The user name lives in the bookmark file. The password goes into your login keychain under the
id of that bookmark, and it is removed when you delete the bookmark. Pick this for a server that
has no IAM, such as one on your own machine.

### AWS IAM

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
- **disable** turns encryption off. Only for a server on your own machine or a private network.
  RDS IAM refuses this mode.

To update the certificate bundle, run `./Scripts/fetch-rds-ca.sh`.

## Where the settings live

| Item | Location |
| --- | --- |
| Bookmarks | `~/Library/Application Support/Rowset/bookmarks.json` |
| Session | `~/Library/Application Support/Rowset/session.json` |
| Saved consoles | `~/Library/Application Support/Rowset/consoles.json` |
| Passwords | The login keychain, service `tech.alcemy.Rowset` |
| Window frame and row limit | `UserDefaults` for `tech.alcemy.Rowset` |

The bookmark file is plain JSON. You can edit it by hand and copy it to another machine.

## The console

The editor holds as many statements as you like.

### Saved consoles

The button beside **Run All** opens the list of saved consoles of this connection. Pick one to
switch to it, or start a new one, or drop the one you are in. Each connection keeps its own list,
so the consoles of one database never appear under another.

The menu also drops every console but the one in front, for a connection that has collected too
many.

A console takes its name from its first line, with the comment marker left off. There is no
rename, because the name follows the text while you type. A new console starts like this, and
shows up in the list as **batch**:

```sql
-- batch

SELECT *
FROM "public"."batch"
LIMIT 50;
```

The empty line after the comment keeps it out of the statement, so the band under the caret
covers the SELECT alone.

Consoles live in `~/Library/Application Support/Rowset/consoles.json` and outlive the tab that
showed them. Deleting a connection deletes its consoles with it.

| Key | What runs |
| --- | --- |
| Command-Return | the statement the caret is in |
| Shift-Command-Return | every statement, one after the other |

The statement the caret is in carries a light band, so you always see what Command-Return will
send.

While the keyboard is in the sidebar, **Command-F** puts it in the filter field. Every editor
keeps that key for its own find bar, so the sidebar takes it only while you are in the sidebar.

**A semicolon is never needed.** Two things end a statement: a semicolon, and an empty line.
Write this and both run on their own:

```sql
SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
 WHERE application_name = 'cube_norman'

SELECT 1
```

A single line break does not end a statement, and must not. A statement is normally written over
several lines, so a SELECT with its FROM on the next line would fall apart.

An empty line inside a string, a comment or a dollar quoted function body splits nothing. The
lexer reports each of those as one piece, and the rule only looks between pieces.

**Run All** stops at the first failure and leaves the result of the last statement on screen. The
statements do not share a transaction, which is what a console does.

### Why a lexer and not tree-sitter

`SQLLexer` reads the text once into keywords, names, strings, numbers, parameters, comments and
punctuation. That one pass serves both jobs:

- **Colouring** needs to know what each piece is.
- **Splitting statements** needs to know which semicolons are real. A split on every semicolon is
  wrong, because one also sits inside a string, inside a quoted name, inside a comment and inside
  a dollar quoted function body.

Neither job asks what the words mean, so a grammar would add a build dependency and buy nothing.
A parser earns its place only for colouring by meaning, such as marking a table apart from a
column. That door stays open.

### From a table to a console

The terminal button beside the value pane button turns a table tab into a console on the query it
was showing:

```sql
-- batch

SELECT * FROM "public"."batch"
WHERE slug = 'x'
ORDER BY created_at DESC;
```

The statement carries no LIMIT and no OFFSET. The page widget puts those around it, and the page
you were on carries over, so the console opens on the same rows the table was showing.

The tab **becomes** a console tab. It runs the same code as one opened from the tab bar, the
title changes to Console, and the query joins the saved consoles of that connection under the
name **batch**.

There is no way back, on purpose. The statement may end up showing another table than the one it
started on, so a filter field or an edit button would then lie about what is on screen. Open the
table again from the sidebar for that.

## Pages

A widget floats over the bottom of the grid:

```
|<   <   1-25 ⌄   of 26+   >   >|
```

- The arrows step a page, and the outer two jump to the first and the last.
- **1-25** opens a menu of page sizes: 25, 50, 100, 200, 500, 1000.
- **of 26+** is what the app knows without asking. Press it to run a count, and the plus turns
  into the real number.

The plus costs nothing. Every page asks the server for **one row more** than it shows. That extra
row never reaches the grid, and it is what says whether another page follows. Only the last page
button needs the real count, so it runs one first.

A new filter, sort, or page size puts you back on the first page and forgets the count, because
all three make the old count wrong.

The widget is the only place that sets the page size. There is no separate row field any more.

### Pages in a console

A console pages as well, when the statement reads. The app wraps it:

```sql
SELECT * FROM (
SELECT * FROM batch WHERE slug LIKE 'a%'
) AS _rowset_page
LIMIT 26
OFFSET 50
```

A statement that writes cannot be wrapped, so an INSERT, an UPDATE, a CREATE or an EXPLAIN runs
as it stands and shows no widget. The rule is the first word: `SELECT`, `WITH`, `TABLE` and
`VALUES` page, and everything else does not.

Editing the statement, or moving the caret to another one, starts the pages and the count again.

## Changing a value

1. Double click a cell. A short value opens a field in the cell. A boolean opens a menu of
   `true`, `false`, and `NULL` where the column takes one. A value of more than one line opens in
   the value pane, where the pencil button starts the edit.
2. Change as many cells as you want. Each one turns yellow, and a bar counts them.
   Select cells and press **Delete** to set them to NULL. A column that takes no NULL is left
   alone, so a block of mixed columns nulls only the ones it may.
3. Press **Submit**. A sheet shows the exact SQL.
4. Press **Run**, or **Cancel**. Nothing reaches the server before you press Run.

Every statement runs in one transaction and ends with `RETURNING 1`. If any statement matches
anything but one row, the whole batch rolls back and the table stays as it was.

**A table without a primary key cannot be edited.** An UPDATE needs a WHERE that finds exactly one
row, and without a key there is none. Rowset does not fall back to `ctid`, because that value
changes under your feet.

The WHERE always holds the key values the server sent, so an edit of a key column still finds the
row it came from.

### What an editor accepts

| Column type | The app checks |
| --- | --- |
| boolean | a menu, so only `true`, `false` or `NULL` |
| integer | a whole number, with an optional sign |
| numeric, real, double | a decimal number, or `NaN` |
| uuid | a UUID |
| json, jsonb | valid JSON |
| date, time, timestamp, interval | nothing. Postgres reads more forms than any rule here would |
| text and everything else | nothing |

A value that does not fit stops in the editor. The text turns red, the tooltip says what is
wanted, and nothing reaches the SQL.

**An empty text is an empty string, not NULL.** Deleting every character of a cell leaves `''`.
NULL comes from the Delete key alone, which is the only way to tell the two apart.

## Design notes

**One connection per bookmark.** Rowset uses `PostgresConnection` and not `PostgresClient`. A
client pools connections and holds one fixed password. An IAM token expires after 15 minutes, so
a pooled connection that opens later would carry a dead token.

**The app decodes every column type itself.** Postgres sends most values in a binary format.
`CellRenderer` turns each type into text. It decodes the date and time types by hand, because a
`Date` loses part of the microsecond precision that Postgres sends.

**Sorting happens on the server.** A click on a column header changes the `ORDER BY` and runs the
query again. A sort inside the app would only order the rows that are already loaded.

**The grid draws a preview, not the value.** A cell can hold a large JSON document. `Text`
measures every string it receives, so a grid of documents stalls while it scrolls. The renderer
builds a short single-line preview once. The grid draws that, and the value pane holds the rest.
A cell also carries no tooltip, because a tooltip adds a tracking area per cell.

**The tab owns its view state.** The sort order, the row limit text, and the selected cell live
on `QueryTab` and not in `@State`. A tab switch then reuses the views instead of building the
whole grid again.

**The value pane uses `NSTextView`.** SwiftUI lays out a whole string at once, which stalls on a
large document. `NSTextView` lays out only the part it draws.

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
