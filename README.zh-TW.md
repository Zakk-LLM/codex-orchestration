# Codex Orchestration Skill

[English](README.md) | 繁體中文

Codex Orchestration 讓協調代理把工作分派給多個 Codex CLI 代理，自己保留規劃、監督、審查與部署。適用於功能開發、重構、缺陷排查、測試補齊、README 與文件撰寫、資料搜集與多檔案稽核。

分工固定：Codex 寫程式碼與草稿，協調者讀真實 diff、執行測試、寫審查結論；commit、merge、發佈只由協調者執行。任務規格明確禁止代理執行改寫歷史的 git 命令。

## 要求

- Codex CLI 0.40 或更新版本，且已完成登入
- Python 3.11 或更新版本
- Bash

## 安裝

```bash
git clone https://github.com/Zakk-LLM/codex-orchestration.git
cd codex-orchestration
./install.sh
```

預設以符號連結安裝到本機已存在的代理目錄。符號連結安裝要求來源目錄保持不變；需要移動或刪除來源目錄時，請先解除安裝，或改用 `--copy`。

```bash
./install.sh claude codex
./install.sh --copy
./install.sh --status
./install.sh --uninstall
```

| 代理 | 安裝位置 |
|---|---|
| Claude | `~/.claude/skills/codex` |
| Codex | `${CODEX_HOME:-~/.codex}/skills/codex` |
| OpenCode | `~/.config/opencode/skills/codex` |

## 使用

協調者應先讀取 [SKILL.md](SKILL.md)。手動執行時，腳本構成完整流程：

```bash
RUN=$(scripts/codex_new_run.sh add-auth-cache)
scripts/codex_capacity.sh medium

scripts/codex_agent.sh --run-dir "$RUN" --label auth-cache \
  --cwd /path/to/repo --sandbox workspace-write --effort high --timeout 1800 \
  --prompt-file "$RUN/agents/auth-cache/prompt.md" \
  --schema "$RUN/schema/impl.json"

scripts/codex_note.sh "$RUN" auth-cache "Token TTL 是 900 秒，不是 3600 秒。"
scripts/codex_wait.sh "$RUN" --handled docs
scripts/codex_status.sh "$RUN"
```

各腳本的 `--help` 列出全部選項。

## 逐一審查，不要等齊

代理的完成時間差距很大，`low` 強度的小修改不到一分鐘，`xhigh` 稽核可能跑二十分鐘。`codex_wait.sh` 阻塞到有代理完成即印出 `<label> <state>`，接著審查該代理、必要時派出修正回合，再把它加入 `--handled` 繼續等待下一個。只有在下一步決策確實需要全部結果時才等齊，例如跨代理的發現去重，或必須一次落地的模組整合。

## 即時補充資訊

`codex exec` 啟動後不再接受輸入，因此新資訊透過代理會重新讀取的檔案送達。任務規格內建的 live-notes 區塊要求代理在每個步驟前重讀 `NOTES.md`，並以最新一條為準：

```bash
scripts/codex_note.sh "$RUN" auth-cache "config.py 的常數已過時，已寫好的檔案也要一併更正。"
```

實測：代理在寫完兩個檔案後讀到新要求，對剩下的檔案套用，並回頭修正已完成的兩個。注意在派工前先建立 `NOTES.md`，且代理最後一個檢查點之後送達的內容不會被讀到，關鍵修正應改用修正回合。

## 資料儲存目錄

每次執行建立一個目錄，保存規劃、任務規格、事件記錄、結果與審查結論，因此審查與後續修正回合都有據可查。預設位置是 `${XDG_CACHE_HOME:-~/.cache}/codex-runs`，可用 `CODEX_RUNS_DIR` 覆寫。不要使用 tmpfs 路徑，因為事件記錄體積大且重開機後消失。

```
<run>/PLAN.md                  分工、可寫範圍與驗收條件
<run>/schema/<name>.json       輸出結構
<run>/agents/<label>/
    prompt.md                  任務規格
    NOTES.md                   執行期間補充的資訊
    events.jsonl               Codex 事件記錄，含每條命令與離開碼
    stderr.log                 錯誤輸出
    result.json 或 last.txt    代理最後的回覆
    thread.txt                 thread id，修正回合與中斷續作用
    meta.json                  離開碼、耗時、token 用量、逾時旗標
<run>/REVIEW.md                每個代理的審查結論
```

## 權限

沙箱是權限邊界，預設取能完成任務的最小值。

| 沙箱 | 授予 | 用於 |
|---|---|---|
| `read-only` | 只讀 | 研究、稽核、審查、規劃、資料搜集 |
| `workspace-write` | 可寫 `--cwd` 與各個 `--add-dir` | 所有實作工作 |
| `danger-full-access` | 不受限 | 未取得使用者當次明確同意即不使用 |

`--network` 只在任務確實需要連線時加入，`--approve-for-me` 只在代理需要合法提權時加入。腳本不提供 `--dangerously-bypass-approvals-and-sandbox`。

## 依任務調度

強度、時限、並行數三者都按任務決定，沒有固定值。

| 強度 | 用於 | `--timeout` |
|---|---|---|
| `low` | 機械式修改、重新命名、格式化、樣板程式碼 | 300–600 |
| `medium` | 預設值：範圍受限的功能、README、既有程式碼的測試 | 900–1800 |
| `high` | 跨多檔案的修改、非顯而易見的缺陷、需保持行為的重構 | 1800–3600 |
| `xhigh` | 架構決策、並行與效能問題、需求含糊 | 3600–7200 |
| `max` | `xhigh` 代理在同一問題上失敗兩次後的最後手段 | 7200 以上 |

時限是失控保護而非進度表，因此估算後再放大約三倍。大任務配短時限最糟：代理在修改到一半時被結束，留下半套變更且沒有任何報告。

並行數由 `codex_capacity.sh` 依核心數、可用記憶體、負載與任務類型計算，機器繁忙時自動減半，可用 `--per-agent-mb` 覆寫記憶體估計。混合任務分組計算，例如三個編譯代理加兩個只讀代理，並保留餘裕給協調者自己執行的測試。

## 中斷與續作

離開碼 124 或 137 表示時限保護結束了代理，`meta.json` 的 `timed_out` 為真，沒有結果檔，工作區留著當下已完成的修改。`thread.txt` 仍然可用，因為 thread id 在執行開始就被記錄，所以續作應恢復同一個 thread，代理會保留既有計畫與對程式碼的理解：

```bash
scripts/codex_agent.sh --run-dir "$RUN" --label auth-cache-cont \
  --resume "$(cat "$RUN/agents/auth-cache/thread.txt")" \
  --cwd /path/to/repo --sandbox workspace-write --effort high --timeout 3600 \
  --prompt-file "$RUN/agents/auth-cache-cont/prompt.md"
```

續作規格要說明上一輪被中斷、目前工作區的實際狀態，以及只需完成的剩餘部分。實測：代理在完成五個檔案中的三個時被結束，恢復後從第四個接續，沒有重做前三個。使用者取消、機器重開、連線中斷都用同一套流程；`thread.txt` 不存在時，可在相同工作目錄用 `codex exec resume --last` 取最近一個工作階段。

同一任務兩次逾時不是時限數值的問題，應把剩餘工作拆成多個代理。

## 已知限制

- `codex exec` 會讀取繼承而來的 stdin，因此 `codex_agent.sh` 以任務規格檔作為 stdin；直接手寫呼叫時需要 `< /dev/null`。
- `codex exec` 沒有內建時間上限，全部呼叫都以 `timeout` 包裝。
- `codex exec resume` 不接受 `-C` 與 `-s`，工作目錄取自行程當前目錄，沙箱改由 `-c sandbox_mode=` 指定。
- 兩個代理寫入同一檔案會互相覆蓋，且派工當下無法偵測，所以檔案歸屬必須在 `PLAN.md` 先分配完成。

其餘失敗情形與處理方式見 [references/troubleshooting.md](references/troubleshooting.md)。

## 文件

- [SKILL.md](SKILL.md)：協調者的完整流程
- [references/prompt-template.md](references/prompt-template.md)：任務規格範本
- [references/schemas.md](references/schemas.md)：實作、稽核、研究三類輸出結構
- [references/troubleshooting.md](references/troubleshooting.md)：失敗情形與處理方式

## 授權

MIT
