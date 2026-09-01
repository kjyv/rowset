# Rowset

A macOS database browser for Postgres, with AWS IAM sign-in.

Pick a saved connection, read a table, filter and sort it, change a value, and run SQL. Rowset
signs in to an RDS instance with an IAM token that it fetches at every connect, or to any other
server with a user and a password.

## What it does

- Saves connections as bookmarks. The bookmark file holds no secret.
- Signs in with AWS IAM or with a user and a password. An IAM token comes from
  `aws rds generate-db-auth-token` at every connect. A password goes into the login keychain.
- Shows schemas, tables, views, and columns in a tree on the left.
- Opens a table in a tab. Each tab has a `WHERE` field, sortable columns, and pages.
  **Command-R** fetches the page again, in a table tab and in a console.
- Shows the whole value of a cell in a pane under the grid. A double click opens the pane, which
  each tab starts without. It formats JSON, colours it, and keeps the key order of the server.
- Moves the picked cell with the arrow keys or with `h`, `j`, `k` and `l`. Shift grows the block.
- Copies a value, a column name, or a whole row from the right click menu of a cell.
- Changes a value and sends the edits together, after it shows you the SQL.
- Runs SQL in a console, one statement at a time or all of them, with the words coloured and the
  statement under the caret marked.
- Remembers the window size and position.

Rowset speaks Postgres. The driver sits behind a protocol, so another one can join it.

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

Build and run from Xcode. To keep the app, copy `Rowset.app` out of the build folder into
`/Applications`.

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

A console belongs to a connection, not to a table. Its editor holds as many statements as you
like, and it runs one of them or all of them.

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
| Command-R | the statement the page belongs to, again |

Command-R brings back what the grid shows, not what the caret is in. A console that has run
nothing to page runs the statement of the caret instead.

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

## Large values

A column of JSON documents or arrays is what makes a wide table slow to open. Reading one such
value costs far more than sending its text, so the grid asks the server for the size of that
column instead, and then reads the values the page can afford.

A value left on the server shows a grey stand-in naming its size, such as `9.6 kB`. It arrives
whole the moment you touch it: a click, the value pane, the row view, an edit and a copy all fetch
the row first, so a stand-in is never what you read, edit or copy. A NULL has no size and stays a
NULL.

This needs a primary key, which is what asks for a row again. A table without one fetches every
value with the page, and so does a table with no large column.

## Reading one whole row

Press **space** on a row. Every column stands under the one before it, with its name and its
type, so a wide table needs no sideways scrolling to read a single row.

- The **arrow keys** walk to the row above or below.
- **Space** again, or **Escape**, closes it.
- **Copy Row** puts the row on the clipboard with its header, in the table formats.

A JSON value is formatted and coloured here as well, in a box of its own that scrolls. The box
stops at 220 points, so one document does not push the other columns out of the window.

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

A new filter puts you back on the first page and forgets the count, because other rows make the
old count wrong.

A new sort keeps the page and the count. It orders the same rows, so neither is wrong. A new page
size keeps the count as well, and the offset moves to the start of the page that now holds the row
you were looking at.

The widget is the only place that sets the page size.

## Pages in a console

A console pages as well, when the statement reads. The app wraps it, and a click on a column
header puts the order on that wrapper:

```sql
SELECT * FROM (
SELECT * FROM batch WHERE slug LIKE 'a%'
) AS _rowset_page
ORDER BY "created_at" DESC
LIMIT 26
OFFSET 50
```

The order sits on the wrapper and not inside your statement, so it holds across every page and
your text stays as you wrote it. Editing the statement clears the sort, because the next one may
carry other columns.

A statement that writes cannot be wrapped, so an INSERT, an UPDATE, a CREATE or an EXPLAIN runs
as it stands and shows no widget. The rule is the first word: `SELECT`, `WITH`, `TABLE` and
`VALUES` page, and everything else does not.

Editing the statement, or moving the caret to another one, starts the pages and the count again.

## Changing a value

1. Double click a cell, or select it and press **Return**. A short value opens a field in the
   cell. A boolean opens a menu of `true`, `false`, and `NULL` where the column takes one. A
   value of more than one line opens in the value pane, already in edit mode.

   **Shift-Return** opens the value pane without starting an edit.
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

A cell that already held NULL is the one exception. It opens an empty field, and leaving that
field empty changes nothing, or every look at a NULL cell would turn it into an empty text. To
put an empty text where a NULL was, use the value pane.

## Design notes

**One connection per bookmark.** Rowset uses `PostgresConnection` and not `PostgresClient`. A
client pools connections and holds one fixed password. An IAM token expires after 15 minutes, so
a pooled connection that opens later would carry a dead token.

**The app decodes every column type itself.** Postgres sends most values in a binary format.
`CellRenderer` turns each type into text. An array is read from its own binary layout rather than
type by type, so an array of timestamps reads as timestamps even though the driver has no decoder
for one. The parse has to end exactly at the end of the buffer, which is what stops it claiming a
type that is no array. It decodes the date and time types by hand, because a
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

**Only a count that goes up asks the pane for an edit.** The grid asks the pane to open an editor
by raising a counter on the tab. A tab with no picked cell has no counter to read at all, so the
step from none to zero is not a request. The counter is read together with the tab that holds it,
because a tab switch reuses the view and the counter of the next tab says nothing about the last
one.

**The value pane sets its text as one attributed string**, so the view never holds a text that is
half painted. It reads `textStorage` to do it, which is safe: only `layoutManager` moves an
`NSTextView` back to TextKit 1, and the pane needs TextKit 2 to lay out a large document by the
part it draws.

**One token type serves SQL and JSON.** `SQLLexer` and `JSONLexer` both give a `SyntaxToken`, and
`SyntaxStyle` paints it, so the editor, the value pane and the row view share one colour table.
The last two share `SyntaxTextView` as well. A JSON value over 200,000 characters stays plain,
because thousands of colour runs make the pane stall.

**The value pane belongs to the tab.** Every tab opens without it. A double click on a cell,
Shift-Return, or the button in the bar brings it, and each tab keeps its own answer in the session
file. A pane that belonged to the window would open in a tab that never asked for one.

**The app is not sandboxed.** It reads `~/.aws/config` and runs the `aws` binary.

## The app icon

The icon is drawn in code:

```sh
./Scripts/make-icon.sh
```

`Scripts/make-icon.swift` draws every size, and `iconutil` builds
`Sources/Rowset/Resources/AppIcon.icns` out of them. Change a color or a proportion, run the
script again, and build. The icns is committed, so a normal build needs no extra step.

`iconutil` builds the file and the asset catalog does not. The catalog compiler keeps four sizes
and stops at 256 points, which leaves out the sizes the Dock and the Finder ask for. `iconutil`
writes all ten, up to 1024 points.

macOS caches an app icon per bundle path, so a fresh icon may not appear at once. To force it:

```sh
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/\
LaunchServices.framework/Versions/A/Support/lsregister -f <path to Rowset.app>
```

## Test

```sh
xcodebuild -project Rowset.xcodeproj -scheme Rowset -destination 'platform=macOS' test
```

The unit tests need no database. They cover the SQL the app builds, the AWS config parser, the
cell renderer, the two lexers, the paging rules, the clipboard formats, and the value pane.

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

Name a table as well, and two more suites run on it:

```sh
ROWSET_MEASURE_TABLE=truck_data ROWSET_MEASURE_LIMIT=50 ./Scripts/live-test.sh
```

`MeasureTests` times the shapes of the page query and prints its numbers with the prefix
`MEASURE`. `LiveGridTests` opens the table through the app itself and checks that every column
the page can afford shows its values and not their sizes.
