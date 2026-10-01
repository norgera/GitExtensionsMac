# Native plugins

Plugins are trusted, in-process application code. Install only plugins you trust.
Swift errors during discovery, registration and execution are reported; a native
crash cannot be isolated from the application. Windows/.NET plugin DLLs do not
load on macOS: their implementation must be ported to this native contract.

## Bundle and SDK

Build an `NSObject` principal class conforming to `GitUI.GitExtensionPlugin`.
Use the matching application's Swift compiler and framework build products; this
is a versioned source SDK, not a promise of binary compatibility across releases.
The bundle must contain:

```text
GitExtensions.Example.bundle/
  Contents/Info.plist
  Contents/MacOS/Example
```

Set `CFBundleExecutable` to `Example`, `NSPrincipalClass` to the module-qualified
class name, and integer `GitExtensionsPluginAPIVersion` to `1` in Info.plist.
Use a stable, unique UUID for `identifier`. The name, description and optional
icon supply menu/settings presentation. Repository-dependent plugins keep the
default `requiresRepository = true`.

The application's internal frameworks are static. **Do not link or embed their
archives into the plugin:** doing so duplicates protocol/class identities.
Compile against their modules, resolving their implementation from the host:

```sh
swiftc -emit-library -module-name Example -F "$products" \
  -Xfrontend -disable-autolink-framework -Xfrontend GitUI \
  -Xfrontend -disable-autolink-framework -Xfrontend GitCommands \
  -Xfrontend -disable-autolink-framework -Xfrontend GitExtensionsCore \
  -Xlinker -undefined -Xlinker dynamic_lookup \
  Example.swift -o GitExtensions.Example.bundle/Contents/MacOS/Example
```

Here `products` is the matching Xcode build-products directory. The deterministic
plugin test compiles and loads an external bundle using this exact boundary.

Install in `~/Library/Application Support/GitExtensionsMac/Plugins` and reopen the
repository. Discovery includes that directory and one child-directory level.
Bundled plugins use `GitExtensions.Plugins.*.bundle`; user plugins use
`GitExtensions.*.bundle`. Discovery errors appear in Installed plugins.

## Execution and lifecycle

`GitUICommands` owns registration, menu dispatch, settings windows and cleanup.
Each repository Browser has its own session/context. Register event handlers in
`register(with:)`; release plugin-owned resources in `unregister(from:)`.
The host releases its event subscriptions when that session closes.

`execute(in:)` returns whether repository refresh is needed. Return `false` for
read-only work. Explicit `requestRepositoryRefresh()` and a `true` execution result
coalesce through the existing notifier while execution is in progress. Raw Git
exit success alone does not prove a repository change.

The host exposes typed `selectedRevisions` (real `ObjectID` values and separate
artificial rows), repository/file/revision interchange context, revision navigation,
existing workflow launch actions, and asynchronous `runGit`. The latter requires
explicit remote/mutation metadata and delegates to the same repository module's
structured Git runner; it is not a separate executable implementation.

`addCommitTemplate(_:text:icon:isRegex:)` and `removeCommitTemplate(_:)` mirror
upstream `IGitUICommands.AddCommitTemplate`/`RemoveCommitTemplate`: registered
templates are process-wide, a duplicate name is ignored, the text closure runs when
the template is chosen, and the Commit dialog lists them before its settings
templates. The built-in GitHub plugin uses them for assigned-issue templates.

Supported lifecycle names are `PostBrowseInitialize`, `PostRegisterPlugin`,
`PostRepositoryChanged`, `PreCommit`, `PostCommit`, `PreCheckoutBranch`,
`PostCheckoutBranch`, `PreCheckoutRevision`, `PostCheckoutRevision`, `PostSettings`,
`PostUpdateSubmodules` and `PostEditGitIgnore` (after the Edit .gitignore /
.git/info/exclude and Add file(s) to .gitignore dialogs close). A Pre handler
returning false vetoes the action. Post action events carry completion state.

Scripts can invoke plugins using `plugin:Name`, `{plugin.Name}`, `{plugin:Name}`
or `{plugin=Name}`. Names are matched case-insensitively. Child-repository scripts
receive a separate child context rather than overwriting a parent session.

## Settings

Plugins can return a custom AppKit settings controller or declare text, password,
boolean, number, choice, path and information fields for the generated editor.
App settings use the stable UUID namespace with the upstream legacy-name fallback;
they do not become Git config. Sources are effective, repository-local, distributed
repository settings, and global app preferences. Repository sources require an
open repository. Effective writes preserve unchanged/default values and choose
local overrides when needed, otherwise global storage.

Blank text means unset/inherit; `<empty string>` stores an explicit empty value.
Text is trimmed, choices/numbers validated, and Reset removes the selected source's
override. Apply persists, Discard reloads, and Cancel discards unapplied edits.
Password fields obscure display but are **not encrypted credential storage**.
Use a custom settings controller and macOS Keychain for secrets; Windows credential
dialogs are not supplied by this SDK.

No NuGet/MEF assembly loader, Windows composition cache, repository-host plugin,
or automatic plugin download is included. Native bundle discovery and AppKit
controllers replace those platform-specific loading/presentation mechanisms.
