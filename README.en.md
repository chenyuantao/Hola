<div align="center">

# Hola

![Supported platform: macOS 12+](https://img.shields.io/badge/platform-macOS%2012%2B-black?logo=apple&logoColor=white)

[简体中文](README.md) · **English**

### Your thoughts, better expressed.

A lightweight macOS menu bar assistant that helps you sound clearer, more natural, and thoughtful before you send.

**Swift / AppKit · Bring your own API credentials · No third-party dependencies**

[Quick start](#quick-start) · [How it works](#how-it-works) · [Language](#interface-language) · [Model settings](#model-settings) · [Compatibility and data](#compatibility-and-data)

</div>

---

## A little more care with every send

You have written what you mean. You just want to get the wording right. Hola helps you do that in the input field you are already using.

Type as usual and press Return. If the draft needs a change, Hola puts the revision back in the same field. Review it, then press Return again to send.

> **Draft**: This plan doesn't work. Fix it and send it tomorrow.
>
> **Illustrative revision**: This plan needs some changes. Please revise it and send it to me tomorrow.
>
> The default prompt asks the model to preserve your meaning without adding information. Results depend on your model and prompt.

| | What Hola offers |
| --- | --- |
| **Polish in place** | Revise in the current input field without copying text between tools |
| **Trigger with Return** | Add a review step before sending; approve revised text yourself |
| **Decide quickly** | Optionally use Jev to check whether a draft needs polishing; if it does not, send the original without waiting for a polishing request |
| **Choose your apps** | Drag in the apps where you want Hola to work |
| **Use your own model** | Connect an OpenAI-compatible service and set your preferred writing style |
| **Stay in your flow** | A menu bar app with progress indicators and request history |

## Quick start

### 1. Install and open

**Download a release (no developer tools required)**

1. Download `Hola-vVERSION-macOS-universal.dmg` from [GitHub Releases](https://github.com/chenyuantao/Hola/releases). It supports both Apple Silicon and Intel Macs.
2. Open the DMG and drag `Hola.app` onto the Applications icon in its Finder window. Then open Hola from Applications and eject the disk image. A ZIP remains available as an alternative.
3. Releases use **a persistent self-signed certificate and are not notarized by Apple**. If macOS says the developer cannot be verified or Apple cannot check the app for malicious software, dismiss the alert and follow the steps below.

| macOS version | Where to allow opening |
| --- | --- |
| macOS 13 and later | **System Settings → Privacy & Security → Security**: find the message about Hola and click **Open Anyway** |
| macOS 12 | **System Preferences → Security & Privacy → General**: find the message about Hola and click **Open Anyway**; unlock the padlock if required |

Authenticate with your password or Touch ID when prompted, then confirm opening. First verify that the download came from this project's Releases page. This adds an exception for Hola only; you do not need to allow all unidentified apps or install and trust a separate certificate. If the button is missing, try opening Hola once, then return to settings. [Apple's instructions](https://support.apple.com/102445)

Allowing the app to open is separate from granting Accessibility and Input Monitoring permissions below. Complete both steps. Hola appears in the menu bar when running.

**Updating a release**: Quit Hola, then replace the old copy in Applications. Releases reuse the same self-signed certificate and app identifier to preserve the signing identity. Upgrading from an older ad-hoc release changes that identity. macOS may ask you to allow opening or grant permissions again. If permissions are enabled but features still fail, remove the old Hola entry from the relevant permission list, add `/Applications/Hola.app` again, enable it, and quit and reopen the app.

**Build from source**

You need macOS 12 or later and Xcode Command Line Tools. If the developer tools are not installed, run:

```bash
xcode-select --install
```

From the project directory, build and restart the app in one step:

```bash
bash scripts/build-and-restart.sh
```

The script builds and signs first, then quits the running development build and opens and verifies `build/HolaDev.app`. Settings opens on General; Commands is the second tab. A failed build leaves the old app running. The installed release `Hola.app` can keep running and is not replaced. On first launch, the development build copies existing settings once; the two versions then store settings separately. macOS requires separate Accessibility and Input Monitoring permissions for `HolaDev.app` because it has its own app ID.

> The app is called **Hola**, with the Chinese brand name **言好**. After upgrading from the previous app identity, grant permissions to Hola again. On first launch, Hola migrates previous settings and history.

The build script creates or reuses the `Hola Local` signing identity in your login keychain, then signs and verifies the app. By default it produces `HolaDev.app` (ID `local.holadev`) with a yellow menu bar icon. The release pipeline produces `Hola.app` (ID `local.hola`) with the standard template icon. This is a local self-signed build, without Developer ID notarization.

### 2. Grant permissions

In **System Settings → Privacy & Security**, grant the following permissions to the copy of Hola you run:

| Permission | Purpose |
| --- | --- |
| Accessibility | Read the current draft and insert its revision |
| Input Monitoring | Handle Return in your selected apps to trigger polishing |

Quit and reopen Hola after granting permissions. Click the **Hola icon** in the menu bar to open Settings.

### 3. Choose apps and a model

1. Open **Settings…** from the menu bar.
2. Drag one or more `.app` files from Applications into the target apps area.
3. Enter the **API URL, Token, and Model** for your OpenAI-compatible provider. Adjust the polishing prompt if needed.
4. Save your settings and click **Enable** in the menu.

Try Return-triggered polishing with a non-sensitive draft in a target app first.

## How it works

```text
Type → Press Return → Check and polish
                          │
                          ├─ No change → Forward Return to the original app
                          │
                          └─ Revised → Insert revision → Review → Press Return again
```

| Situation | What happens |
| --- | --- |
| The revision matches the original, ignoring surrounding whitespace | Hola forwards Return; in chat apps where Return sends, the original is sent |
| The revision differs | Hola inserts it into the original field and waits for you to press Return again |
| You edit the inserted revision | The next Return starts a new polishing request |
| An API request fails | Nothing is sent automatically; a failure is shown and you can press Return to retry |
| The input field cannot be read | That Return is blocked and an error is shown |
| Writing fails or cannot be verified | Nothing is sent automatically; check the actual text in the field before continuing |
| You use Return with Shift, Command, or another modifier | The original app handles it as usual |

Each target app has an intercept scope. The default is **Intercept all**: Return in any of that app's fields follows the flow above.

With **Intercept some**, the first Return in a field asks beside that field:

| Choice | This Return | Afterwards |
| --- | --- | --- |
| Don't intercept | The original app handles it | Return in this field is left alone |
| Allow | Polishing starts | Later Returns in this field are intercepted |
| Not now | The original app handles it | Nothing is remembered, so the next Return asks again |

Saved choices appear under the app in Settings. You can switch a choice, or select **Ask again** to be prompted next time. Switching back to Intercept all keeps those choices, but every field is intercepted until you change the scope again. Save settings before a scope change takes effect.

While processing, a **Polishing** indicator appears near the input field and the menu bar shows progress. A **green dot** indicates success; a **red dot** indicates failure. Open **History…** to inspect originals, revisions, prompts, and processing details.

## Startup settings

Enable **Launch at Login** in Settings on macOS 13 or later. If macOS requests approval, allow Hola in the system Login Items settings. On macOS 12, add Hola manually in System Preferences → Users & Groups → Login Items.

Whenever Hola opens, it automatically enables Return handling if Accessibility and Input Monitoring permissions and a target app are available. Stopping it manually affects only the current run. If it cannot start, the menu status shows why. A yellow dot on the menu bar icon indicates that Hola is not enabled.

## Interface language

At launch, Hola follows your primary system language, including the per-app language preference available in macOS:

| Preferred language | Interface |
| --- | --- |
| Chinese, including Simplified, Traditional, and regional variants | Simplified Chinese |
| English or any other language | English |

Menus, settings, status messages, errors, and the history interface are available in both languages. Quit and reopen Hola after changing the system or app language.

Default prompts follow the interface language but ask the model to **keep the draft's original language**. An English interface does not ask the model to translate Chinese drafts into English. Saved custom prompts, drafts, and history content stay unchanged; historical processing notes retain the language used when recorded. Switch README languages manually using the links at the top.

## Model settings

### Polishing service

Hola supports OpenAI-compatible `chat/completions` services. Enter a Base URL or the complete endpoint URL.

| Setting | Description |
| --- | --- |
| API URL | Your provider's Base URL, such as `https://api.openai.com/v1` |
| Token | Your API credentials for that provider |
| Model | A model name supported by the endpoint |
| Extra request parameters | Optional JSON object merged into the Chat Completions request, for example `{"reasoning_effort":"high","stream":false}`. Cannot override `model` or `messages`; only `stream: false` is supported |
| Polishing prompt | Your preferred style: more natural, concise, or suitable for work |

Requests default to `stream: false`. Recognized reasoning models also default to `{"reasoning_effort":"low"}`; other models receive no automatic reasoning parameter. Values in extra request parameters take precedence.

Default English polishing prompt:

> You are a writing assistant. Keep the original language and meaning, and do not add new information. Make the draft clearer, more natural, and appropriate in tone. Output only the revised text, without quotation marks or explanations.

### Optional Jev check

Jev is disabled by default. When enabled, it first decides whether a draft needs polishing.

| Mode | Flow |
| --- | --- |
| **Default: Jev disabled** | Each round requests a revision; Hola forwards Return or inserts the revision depending on the result |
| **Jev enabled** | Check first; forward Return if no revision is needed, otherwise call the polishing service |

### Commands

Add rules in the **Commands** tab of Settings. Rules match the full original input in order; for example, `^#` matches drafts beginning with `#`. Each script is a function expression. Hola calls it with the original draft as `input`; it may return the result object or a Promise of it:

```javascript
async (input) => {
  return { interrupt: true, replacement: input.slice(1) };
}
```

`interrupt: true` blocks this Return and inserts a nonempty `replacement` when provided. Press Return again to send the inserted draft. `interrupt: false` continues the normal polishing flow and ignores `replacement`. Script or replacement failures do not send the draft. Commands run only in selected target apps.

Rules match from top to bottom. Drag the handle on the left to change priority. Enter a draft and click **Test** to print the script result, or **No match** when nothing matches. The test uses the rules currently being edited, without saving first.

Use `fetch` for network requests. It follows the [Fetch standard](https://fetch.spec.whatwg.org/). Scripts can `await fetch(url, init)`. `Headers`, `Request`, `Response`, `AbortController`, `FormData`, `Blob`, and `URLSearchParams` are also available. HTTP 4xx/5xx responses do not reject the promise; check `response.ok`. An invalid URL, a connection failure, or an integrity mismatch rejects with `TypeError`. Aborting through `AbortSignal` rejects with `AbortError` or `TimeoutError`. The whole script, including `fetch`, must finish within 10 seconds; a timeout does not send the draft.

```javascript
async (input) => {
  const response = await fetch("https://example.com/rewrite", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ text: input }),
  });
  if (!response.ok) throw new Error(String(response.status));
  const data = await response.json();
  return { interrupt: true, replacement: data.text };
}
```

Use **Export / Import** in Settings to transfer your target app list, model configuration, and commands. Import replaces the corresponding settings present in the file. Exported files contain API tokens and command scripts; keep them private.

## Compatibility and data

**Support depends on the input field.** Hola reads and writes the `AXValue` of ordinary text fields through macOS Accessibility. Custom editors and apps that do not expose this capability may not work. Adding an app does not establish compatibility. Sending also depends on how the target app handles Return.

Drafts with images or other embedded objects are sent to the model with `<object id="…">` tokens. Hola refuses revisions that alter those tokens. If the text changes, it edits only the text around objects when the target field supports selected-text replacement, avoiding a full overwrite of the attachments.

Before inserting a revision or forwarding Return, Hola checks the foreground app, input field, and draft. AX reads and writes are not atomic, and apps can reuse input fields in ways Hola cannot distinguish. Wait for processing to finish, and trigger a new request after changing conversations. With an input method, commit any composition or candidate text first.

- **Scope**: The draft in the selected app's focused text field. Hola does not collect chat history or read password controls.
- **Model requests**: Drafts go to your configured polishing service, and also to Jev when its check is enabled.
- **Local settings**: Settings and API tokens are stored in `UserDefaults`; tokens are not currently stored in Keychain.
- **History**: The latest 100 records, including drafts, results, and prompts, are stored locally. Clear them from the History window.

<details>
<summary>Local history file</summary>

```text
~/Library/Application Support/local.hola/round-history.json
~/Library/Application Support/local.holadev/round-history.json (development build)
```

</details>

## Development and validation

Hola uses Swift and system frameworks, with no third-party source dependencies.

| File | Contents |
| --- | --- |
| [Sources/main.swift](Sources/main.swift) | Menu bar, settings, draft access, model requests, and history |
| [Sources/Localization.swift](Sources/Localization.swift) | Language selection and localized text formatting |
| [Resources](Resources) | English and Chinese strings, app and menu bar icons |
| [build.sh](build.sh) | Compilation, app packaging, and local signing |
| [Info.plist](Info.plist) | App identity and system configuration |
| [Manual checks](docs/MANUAL_TESTS.md) | App, API, and input behavior checks (Chinese) |
| [Validation record](docs/VALIDATION.md) | Completed checks and outstanding validation (Chinese) |

Run `bash scripts/test-localization.sh` after building to check language selection, resource completeness, and dynamic messages.

Build and signing checks have passed on macOS. **End-to-end validation with real model credentials and target apps is still pending.**

---

<div align="center">

**Hola**<br>
Your thoughts, better expressed.

</div>
