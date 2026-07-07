# Estrutura de configuração dos agentes de código (Julho / 2026)

Comparação da **estrutura completa de configuração** de cinco agentes de código, nas sete
dimensões: arquivos `.md` de instrução, `hooks`, `rules`, `skills`, `sub-agents`, `memory`
e `prompts`/slash-commands (mais `config`/`settings` e `MCP`).

**Ferramentas:** OpenAI **Codex** · Anthropic **Claude Code** · xAI **Grok** (Grok Build) ·
Google **Gemini CLI** · Microsoft/GitHub **Copilot**.

**Precisão das fontes** (verificado nesta ordem):

| Ferramenta | Fonte | Confiança |
|---|---|---|
| Claude Code | `code.claude.com/docs` | 🟢 1ª mão |
| Codex | `developers.openai.com/codex` (via connector openai-docs) | 🟢 1ª mão |
| Grok | `docs.x.ai/build` (via connector xai-docs) | 🟢 1ª mão |
| Copilot | `docs.github.com` + `learn.microsoft.com` (connector) + `code.visualstudio.com` | 🟢 1ª mão |
| Gemini CLI | `raw.githubusercontent.com/google-gemini/gemini-cli` | 🟡 raw do repo oficial |

---

## 1. Arquivos de memória / instrução (`.md`)

| | Arquivo principal | Localizações (ordem de carga) | Import | Notas |
|---|---|---|---|---|
| **Claude Code** | `CLAUDE.md` | managed → `~/.claude/CLAUDE.md` → `./CLAUDE.md` ou `./.claude/CLAUDE.md` → `./CLAUDE.local.md` (concatenados) | `@path` (máx 4 hops) | lê só CLAUDE.md; importa `@AGENTS.md` |
| **Codex** | `AGENTS.md` | `~/.codex/AGENTS.md` → git-root → dirs intermediários → cwd (concatenados root→cwd, **cwd vence**) | `project_doc_fallback_filenames` | `AGENTS.override.md` substitui no nível; cap **32 KiB** (`project_doc_max_bytes`) |
| **Grok** | família `AGENTS.md` | `~/.grok/` → repo-root→cwd (**arquivo mais profundo vence, sem cap**) | — | aceita `AGENTS.md`/`Agents.md`/`AGENT.md`/`CLAUDE.md`/`Claude.md`/`CLAUDE.local.md` + `.grok/rules/*.md`. **NÃO usa GROK.md** |
| **Gemini CLI** | `GEMINI.md` | `~/.gemini/GEMINI.md` → projeto+ancestrais → subdir just-in-time (concatenados) | `@file.md` | aceita `AGENTS.md`; setting `context.fileName` |
| **Copilot** | `.github/copilot-instructions.md` + `AGENTS.md` | repo-wide + `.github/instructions/**/*.instructions.md` (`applyTo:`) + `AGENTS.md` (o mais próximo vence) | — | `CLAUDE.md`/`GEMINI.md` só na raiz; pessoal `~/.copilot/copilot-instructions.md` |

## 2. Rules

| | Tem "rules" dedicado? | Como |
|---|---|---|
| **Claude Code** | ✅ first-class | `.claude/rules/*.md` (projeto) e `~/.claude/rules/*.md`; frontmatter `paths:` (glob) → carga condicional; sem `paths` = sempre |
| **Grok** | ✅ | `.grok/rules/*.md` + família `AGENTS.md`; lê `.claude/rules/` e `.cursor/rules/` por compat |
| **Copilot** | ⚠️ via instructions | `*.instructions.md` com `applyTo:` glob; VS Code também lê `.claude/rules` (com `paths:`) |
| **Codex** | ❌ | regras vão em `AGENTS.md` + hooks + permission profiles |
| **Gemini CLI** | ❌ (CLI) / ✅ (Code Assist) | Code Assist: `.idx/airules.md` → `GEMINI.md` → `.gemini/styleguide.md` → `AGENTS.md` |

## 3. Hooks

| | Config | Eventos | Notas |
|---|---|---|---|
| **Claude Code** | `settings.json` chave `hooks` + plugin `hooks/hooks.json` | ~30: `SessionStart`, `PreToolUse`, `PostToolUse`, `PostToolBatch`, `PermissionRequest/Denied`, `SubagentStart/Stop`, `Stop`, `PreCompact/PostCompact`, `InstructionsLoaded`, `FileChanged`, `WorktreeCreate`… | handlers `command`/`http`/`mcp_tool`/`prompt`/`agent` |
| **Codex** | `~/.codex/hooks.json`, `.codex/hooks.json`, inline `[hooks]` no `config.toml`, `requirements.toml` (managed), plugin `hooks/hooks.json` | **PascalCase** — turn: `PreToolUse`, `PermissionRequest`, `PostToolUse`, `PreCompact`, `PostCompact`, `UserPromptSubmit`, `SubagentStop`, `Stop`; thread: `SessionStart`, `SubagentStart` | habilitado por padrão (`[features] hooks=false`); timeout default **600s**; hoje só `type:"command"` roda; trust via `/hooks` |
| **Grok** | `~/.grok/hooks/*.json` (user), `.grok/hooks/*.json` (projeto, exige `/hooks-trust`) | `SessionStart/End`, `UserPromptSubmit`, `PreToolUse` (único que bloqueia), `PostToolUse/Failure`, `PermissionDenied`, `Stop/StopFailure`, `Notification`, `SubagentStart/Stop`, `PreCompact/PostCompact` | lê hooks Claude/Cursor; `matcher` regex, `type` command/http, timeout seg (default 5); trust em `~/.grok/trusted_folders.toml` |
| **Gemini CLI** | `settings.json` chave `hooks` | `BeforeTool`, `AfterTool`, `BeforeAgent`, `AfterAgent`, `BeforeModel`, `AfterModel`, `BeforeToolSelection`, `SessionStart`, `SessionEnd`, `Notification`, `PreCompress` | stdin JSON / stdout JSON |
| **Copilot** | `.github/hooks/*.json` (`"version":1`) + user-level CLI | `sessionStart`, `sessionEnd`, `userPromptSubmitted`, `preToolUse`, `postToolUse`, `errorOccurred` | `preToolUse` pode aprovar/negar |

## 4. Skills (`SKILL.md`)

Padrão convergente (`SKILL.md` com frontmatter `name` + `description`).

| | Localizações |
|---|---|
| **Claude Code** | `~/.claude/skills/<n>/SKILL.md`, `.claude/skills/`, plugin `skills/`; invoca `/<n>` ou auto |
| **Codex** | escaneia **`.agents/skills/`** de cwd→repo-root (REPO), `~/.agents/skills/` (USER), `/etc/codex/skills` (ADMIN), SYSTEM bundled; `[[skills.config]]` desativa; `agents/openai.yaml` metadata; invoca `/skills` ou `$skill` |
| **Grok** | `.grok/skills/` (→repo-root), `~/.grok/skills/`, `~/.agents/skills/`, plugin `skills/`, `[skills] paths` |
| **Gemini CLI** | `~/.gemini/skills/` (alias `~/.agents/skills/`), `.gemini/skills/`; tool `activate_skill`; `/skills list…` |
| **Copilot** | `.github/skills/`, `.claude/skills/`, `.agents/skills/`; pessoal `~/.copilot/skills/`, `~/.agents/skills/`. Frontmatter: `name`(≤64), `description`(≤1024), opc. `license`/`compatibility`/`metadata`/`allowed-tools`; `discovery: lazy\|preload` |

## 5. Sub-agents

| | Definição | Localização | Campos-chave |
|---|---|---|---|
| **Claude Code** | Markdown + frontmatter (corpo = system prompt) | `.claude/agents/*.md`, `~/.claude/agents/`, managed, plugin | `name`, `description`, `tools`, `model`, `permissionMode`, `isolation: worktree`, `memory`, `hooks` |
| **Codex** | **TOML**, 1 por arquivo | `~/.codex/agents/<n>.toml`, `.codex/agents/` | obrig. `name`, `description`, **`developer_instructions`**; opc. `model`, `model_reasoning_effort`, `sandbox_mode`, `mcp_servers`, `skills.config`, `nickname_candidates`. `[agents]` `max_threads`(6)/`max_depth`(1). Built-ins `default`/`worker`/`explorer`. `/agent` |
| **Grok** | agent definition (via `GROK_AGENT`/`/config-agents`) | config `[subagents]` | `[subagents].enabled`, `[subagents.toggle]`, `[subagents.models]`; `GROK_SUBAGENTS=1`; sessões-filhas paralelas; `/fork` peer-agent; worktrees |
| **Gemini CLI** | Markdown + frontmatter (abr/2026) | `.gemini/agents/*.md`, `~/.gemini/agents/` | `name`, `kind`(local/remote), `tools`, `model`, `max_turns`; invoca `@nome`; built-ins `codebase_investigator`… |
| **Copilot** | `<n>.agent.md` (Markdown+frontmatter) | `.github/agents/`; user `%USERPROFILE%\.github\agents` | `description`(obrig), `name`/`model`/`tools`(opc), `target`, `handoffs`, `user-invocable`; `.chatmode.md` legado ainda funciona |

## 6. Prompts / slash-commands

| | Formato | Localização |
|---|---|---|
| **Claude Code** | Markdown (mesmo engine de skills) | `.claude/commands/*.md`, `~/.claude/commands/`; **fundidos em skills** (2026) |
| **Codex** | Markdown top-level | `~/.codex/prompts/*.md` → `/nome`; **DEPRECADO** → usar skills |
| **Grok** | skills viram slash-commands | `~/.agents/commands/` (user); sem `.grok/commands/`; forma qualificada `/local:commit` |
| **Gemini CLI** | **TOML** (`prompt`, `description`) | `~/.gemini/commands/`, `.gemini/commands/`; namespacing `/git:commit`; `{{args}}`, `!{...}`, `@{...}` |
| **Copilot** | `*.prompt.md` (VS Code) | `.github/prompts/`; frontmatter `mode`/`model`/`tools`; invoca `/nome`. CLI usa agents+skills |

## 7. Config / settings + MCP

| | Config | Formato | MCP |
|---|---|---|---|
| **Claude Code** | `~/.claude/settings.json`, `.claude/settings.json`, `.local.json`, managed | JSON — Managed→CLI→Local→Project→User | `.mcp.json` / `~/.claude.json` |
| **Codex** | `~/.codex/config.toml`, `.codex/config.toml`, `requirements.toml` | **TOML**; profiles `~/.codex/<n>.config.toml` | `[mcp_servers.<n>]` no config.toml |
| **Grok** | `~/.grok/config.toml` (full), `.grok/config.toml` (só `[mcp_servers]`/`[plugins]`/`[permission]`) | **TOML** + `sandbox.toml`; `GROK_HOME` | `grok mcp add` / `[mcp_servers.<n>]` |
| **Gemini CLI** | system → `.gemini/settings.json` → `~/.gemini/settings.json` → system-defaults | JSON; `$VAR` + `.env` | `mcpServers` no settings.json |
| **Copilot** | VS Code `github.copilot.chat.*`; CLI `~/.copilot/settings.json`+`config.json` | JSON | `.vscode/mcp.json` / `~/.copilot/mcp-config.json` |

---

## Padrões (Julho 2026)

- **`SKILL.md` e `AGENTS.md` viraram padrões cross-agent.** Codex/Grok/Gemini/Copilot leem `AGENTS.md`; só o Claude Code prioriza `CLAUDE.md` (mas importa AGENTS.md). Todos os 5 adotaram `SKILL.md` com o mesmo frontmatter.
- **Hooks chegaram a todos em 2026** — antes só Claude/Codex; Gemini e Copilot adicionaram este ano.
- **Formato divide o campo:** Claude/Gemini/Copilot usam **JSON**; Codex/Grok usam **TOML**. Sub-agents: Claude/Gemini/Copilot em Markdown, Codex em TOML.
- **Interoperabilidade explícita:** o **Grok Build lê a stack inteira do Claude Code com zero config** (marketplaces, plugins, skills, MCPs, agents, hooks, `CLAUDE.md`, `.claude/rules/`) + diretórios do Cursor. Copilot lê `.claude/skills` e `.claude/rules`. Gemini lê `AGENTS.md`.
- **Memory persistente:** Claude Code (`~/.claude/projects/.../memory/`, auto memory) e Grok (`[memory]`, `/remember`/`/dream`) têm memória cross-session nativa.

## Fontes

- Claude Code — code.claude.com/docs/en/{memory,settings,hooks,skills,sub-agents,mcp,plugins}
- Codex — developers.openai.com/codex/{guides/agents-md,hooks,skills,subagents,config-reference,mcp}
- Grok — docs.x.ai/build/{overview,settings/reference,features/hooks,features/project-rules,features/skills-plugins-marketplaces,modes-and-commands}
- Gemini CLI — github.com/google-gemini/gemini-cli/docs/{cli/gemini-md,hooks/reference,core/subagents,cli/custom-commands,tools/mcp-server}
- Copilot — docs.github.com/copilot/* · code.visualstudio.com/docs/agent-customization/* · learn.microsoft.com (Visual Studio / SSMS / modernization agent)
