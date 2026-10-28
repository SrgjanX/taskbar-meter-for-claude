# CLAUDE.md

Guidance for Claude (and other AI assistants) working in this repository.

## PUBLIC REPOSITORY: no sensitive data, ever

This repository is **public on GitHub**. Anything committed can be seen by anyone and stays in the git history even after it's deleted.

**Before every commit, always check that nothing sensitive is being committed.** Do this every time, even for a one-line change, and don't skip it because a change "looks harmless".

### Pre-commit checklist

1. Review exactly what will be committed:
   ```
   git status
   git diff --cached
   ```
2. Scan the staged changes for sensitive data:
   ```
   git diff --cached | grep -niE "sk-ant|bearer [a-z0-9]|api[_-]?key|secret|passw|token\"?\s*[:=]|eyJ[a-z0-9]"
   git diff --cached | grep -noE "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}"
   git diff --cached | grep -niE "C:\\\\Users\\\\|/Users/|/home/"
   git diff --cached | grep -noE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b"
   ```
3. Make sure no forbidden files are staged (see the list below).
4. For images, look at every new or changed screenshot. Check that it shows no real email, account name, file path, notifications, browser tabs, or other personal info.
5. If anything is found, **stop**: unstage it, remove the data, and tell the user. Never commit it "to fix later".
6. If something sensitive was *already* committed, tell the user right away. Deleting it in a new commit doesn't remove it from history, and a leaked token must be revoked or rotated.

### Never commit

- OAuth tokens, API keys, or any `sk-ant-...` value
- `.credentials.json` or anything else from `%USERPROFILE%\.claude\`
- Output of `-DumpJson` pasted from a real account (use made-up example numbers instead)
- `%APPDATA%\ClaudeTaskbarWidget\settings.json` or other local settings
- Personal email addresses, usernames, real names, or machine-specific paths, except the author name already in LICENSE
- Logs, crash dumps, `.env` files, or real screenshots that haven't been reviewed

`.gitignore` blocks the common cases, but it is a safety net, not a replacement for the checklist.

## Project overview

`claude-taskbar-widget.ps1` is a single PowerShell script (WinForms) that draws a small borderless, always-on-top "pill" on the Windows taskbar showing Claude plan usage:

- `5h`: session limit, `7d`: weekly limit, colored green (<50%), amber (>=50%), red (>=80%)
- The tooltip shows reset times, model-specific weekly limits, and extra usage
- Data source: `GET https://api.anthropic.com/api/oauth/usage` with header `anthropic-beta: oauth-2025-04-20`, authenticated with the Claude Code OAuth token from `%USERPROFILE%\.claude\.credentials.json` (or `%CLAUDE_CONFIG_DIR%`). This endpoint is **undocumented** and may change. `ConvertTo-Windows` handles both the flat keys (`five_hour`, `seven_day`, ...) and the newer `limits` array.
- The token must only ever be sent to `api.anthropic.com`. Never log it, display it, write it to disk, or send it anywhere else.

## Repository layout

```
claude-taskbar-widget.ps1   the widget (the only code file)
README.md                   user-facing docs
LICENSE                     MIT
docs/screenshot.png         README hero image (mockup)
docs/states.png             README color-states image (mockup)
```

## Conventions

- **Must run on Windows PowerShell 5.1** as well as PowerShell 7+. Avoid 7-only syntax (`??`, `?.`, ternary `a ? b : c`, `&&`/`||` pipelines, `ForEach-Object -Parallel`).
- **Keep the script pure ASCII.** PowerShell 5.1 misreads UTF-8 files without a BOM, so no smart quotes, em dashes, or symbols.
- No external modules or downloads. Use only what ships with Windows (.NET Framework, WinForms, user32 via `Add-Type`).
- Sizes go through `Px` so they scale with DPI.
- Keep it to a single file so users can download one script.
- If the visible pill changes, update the README text and the images in `docs/` to match.

## Validating changes

There is no test suite. Before committing a code change:

1. Check the syntax:
   ```powershell
   $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile("$PWD\claude-taskbar-widget.ps1", [ref]$null, [ref]$e); $e
   ```
2. Run the linter, if it's available:
   `Invoke-ScriptAnalyzer .\claude-taskbar-widget.ps1`. The plural-noun, ShouldProcess, Write-Host and empty-catch warnings are known and accepted.
3. Check that the file is still ASCII-only: `Select-String -Path .\claude-taskbar-widget.ps1 -Pattern '[^\x00-\x7F]'` should return nothing.
4. Run it on Windows and check the pill, tooltip, drag, double-click and right-click menu.
5. **Run the sensitive-data checklist above.**

## Commits

- Write a clear, short commit message describing the change.
- Commit or push only when the user asks.
