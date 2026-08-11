# Codex Orchestration Skill

[English](README.md) | 繁體中文

Codex Orchestration 讓協調代理把工作分派給多個 Codex CLI 工作代理，並保留規劃、監督、審查與部署。適用於功能開發、重構、缺陷排查、測試補齊、文件撰寫、資料搜集與多檔案稽核。

分工固定：工作代理只產出程式碼與草稿；協調者讀真實 diff、執行測試、寫審查結論；commit、merge、發佈由協調者執行。任務規格明確禁止工作代理執行改寫歷史的 git 命令。

## 為什麼派工給 Codex

**上下文**。工作代理在自己的上下文視窗內探索，只回傳受限的結果。本專案自己的研究執行中，三個工作代理合計消耗 1260 萬輸入 token，協調者只讀了三個結果檔；那些探索過程從未進入協調者的上下文。

**依難度分配成本**。`--tier` 同時決定推理深度與模型，機械性工作因此不會用最高推理深度執行，也不會留在昂貴的對話裡。

**獨立性**。工作代理沒有協調者的推理記憶，無法繼承協調者的錯誤假設，這正是它能作為第二意見的原因。

**可續作**。每個工作單位都有 thread、執行目錄與經結構驗證的結果。代理中途死亡可以續作，需要解析的結果是 JSON 而非散文。

代價是每個工作代理需要協調者一次審查。這個技能的其餘部分都在管理這個取捨。

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

預設以符號連結安裝到本機已存在的代理目錄。符號連結要求來源目錄保持不變；需要移動或刪除來源目錄時，先解除安裝或改用 `--copy`。

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

協調代理先讀取 [SKILL.md](SKILL.md)。手動執行時，腳本構成完整流程：

```bash
RUN=$(scripts/codex_new_run.sh add-auth-cache)
scripts/codex_capacity.sh medium

scripts/codex_agent.sh --run-dir "$RUN" --label auth-cache \
  --cwd /path/to/repo --worktree --sandbox workspace-write \
  --effort high --timeout 1800 --stall 300 \
  --prompt-file "$RUN/agents/auth-cache/prompt.md" \
  --schema "$RUN/schema/impl.json"

scripts/codex_note.sh "$RUN" auth-cache "Token TTL 是 900 秒。"
scripts/codex_dispatch.sh --run-dir "$RUN" --jobs "$RUN/jobs.jsonl" --weight medium
scripts/codex_verify.sh "$RUN" auth-cache --check "pytest -q"
scripts/codex_wait.sh "$RUN" --handled docs
scripts/codex_status.sh "$RUN"
scripts/codex_worktrees.sh "$RUN" --diff main
```

各腳本的 `--help` 列出全部選項。

`codex_dispatch.sh` 讀取 JSONL 工作清單，每行一個代理，指定 label、難度級別與與預設不同的選項，然後依難度由高到低派工，並行數取自本機容量。`--dry-run` 只印出將執行的命令。

需要保護的是派工方的上下文。工作代理的上下文用完即棄，為單一任務建立、隨任務結束消失，因此工作代理要讀多少就讀多少，不會為了節省它的上下文而拆分任務或縮短規格。只有最終報告受限，因為那是進入協調者的部分。協調者只讀 `result.json` 與 `verify.json`，以 `codex_status.sh` 作為摘要，失敗時才打開 `events.jsonl`，並以路徑引用產物而非貼上內容。唯一的例外是 `--resume` 會把整個 thread 當作輸入重播，那是成本，不是限制。

## 何時才分派多代理

多代理只在工作能真正拆解時有效。廣度優先的工作（獨立模組、大範圍搜尋、同一處理套用到多個檔案）受益明顯；共用上下文或有依賴鏈的工作則相反，受控實驗顯示各種多代理拓撲在循序規劃任務上比單一代理差 39% 至 70%。

限制不在代理數量，而在協調者的審查產能。每個完成的代理都需要一次 diff 閱讀與一次測試執行。同時保持約三個需要審查的代理，只有淺層且一致的工作才提高。

## 並行寫入與 git worktree

`--worktree` 為每個可寫代理建立獨立工作區與 `codex/<label>` 分支，主工作區不受影響，衝突移到合併階段才出現且可審查。已測量的背景：跨代理的同期 PR 有 41.7% 出現文字衝突，同一代理為 19.8%。

```bash
scripts/codex_worktrees.sh "$RUN" --list
scripts/codex_worktrees.sh "$RUN" --remove-merged main
```

`--remove-merged` 只刪除已併入指定分支的工作區，未合併的工作不會遺失。含 submodule 的倉庫改用完整 clone，因為 git 對多個 superproject checkout 的支援不完整。

## 逐一審查，不要等齊

完成時間差距很大：`low` 強度的小修改不到一分鐘，`xhigh` 稽核可能跑二十分鐘。`codex_wait.sh` 阻塞到有代理完成即印出 `<label> <state>`；審查該代理、必要時派出修正回合，再把它加入 `--handled` 繼續等下一個。只有在下一步決策確實需要全部結果時才等齊，例如跨代理發現去重，或必須一次落地的模組整合。

## 審查閘門

工作代理的報告只是主張，實際執行過的命令才是證據，兩者不可互換。信心十足的摘要、看起來合理的 diff、另一個代理的通過結論，都不構成接受的理由。`codex_verify.sh` 將可機械化的部分固定下來：沒有執行任何驗收命令，或有檔案落在規格宣告的 `Write:` 範圍之外時，一律回報 `not-verified`。

```bash
scripts/codex_verify.sh "$RUN" auth-cache \
  --check "pytest tests/test_auth.py -q" --check "ruff check src/"
```

`verify.json` 記錄改動檔案、越界檔案，以及每條命令的離開碼與輸出尾段；建置產物另行列出，不算越界。其餘需要判斷的步驟仍由協調者執行：逐行讀 diff、跑反向對照確認測試在沒有該修改時確實失敗、檢查是否有削弱斷言或吞掉例外這類靜默通過。研究結果同樣處理，抽查來源並確認引述數字確實出現在該頁。完整流程見 [references/review-gate.md](references/review-gate.md)。

## 即時補充資訊

`codex exec` 啟動後不接受任何輸入，stdin 在開始時即讀到 EOF，SIGINT 是唯一被解讀的訊號。因此新資訊透過工作代理會重讀的檔案送達：任務規格的 live-notes 區塊要求每個步驟前重讀 `NOTES.md`，以最新一條為準。

```bash
scripts/codex_note.sh "$RUN" auth-cache "config.py 的常數已過時，已寫好的檔案一併更正。"
```

實測：工作代理在寫完兩個檔案後讀到新要求，對剩下的檔案套用，並回頭修正已完成的兩個。派工前先建立 `NOTES.md`；最後一個檢查點之後送達的內容不會被讀到，關鍵修正改用修正回合。

## 資料儲存目錄

每次執行建立一個目錄，保存規劃、任務規格、事件記錄、結果與審查結論，讓審查與後續續作都有據可查。預設位置為 `${XDG_CACHE_HOME:-~/.cache}/codex-runs`，以 `CODEX_RUNS_DIR` 覆寫。不要指向 tmpfs 路徑，因為事件記錄體積大且重開機後消失。

```
<run>/PLAN.md                  分工、可寫範圍與驗收條件
<run>/schema/<name>.json       輸出結構
<run>/worktrees/<label>/       該代理的獨立工作區
<run>/agents/<label>/
    prompt.md                  任務規格
    NOTES.md                   執行期間補充的資訊
    events.jsonl               Codex 事件記錄，含每條命令與離開碼
    stderr.log                 錯誤輸出
    result.json 或 last.txt    最後回覆
    verify.json                審查閘門：範圍檢查與每條驗收命令的結果
    thread.txt                 thread id，供修正回合與續作
    meta.json                  離開碼、耗時、token 用量、逾時與停滯旗標、改動檔案
<run>/REVIEW.md                每個代理的審查結論
```

原始記錄留在執行目錄，協調者只讀摘要與 diff，需要時才展開細節，避免自身上下文被工作輸出淹沒。

## 權限

沙箱是權限邊界，預設取能完成任務的最小值。

| 沙箱 | 授予 | 用於 |
|---|---|---|
| `read-only` | 只讀 | 研究、稽核、審查、規劃、資料搜集 |
| `workspace-write` | 可寫 `--cwd` 與各個 `--add-dir` | 所有實作工作 |
| `danger-full-access` | 不受限 | 未取得使用者當次明確同意即不使用 |

`--network` 只在任務確實需要連線與檢索時加入，`--approve-for-me` 只在代理需要合法提權時加入。腳本不提供 `--dangerously-bypass-approvals-and-sandbox`。

## 依任務調度

強度、時限、並行數都按任務決定，沒有固定值。

| `--tier` | 強度 | 用於 | `--timeout` |
|---|---|---|---|
| `cheap` | `low` | 機械式修改、重新命名、格式化、樣板程式碼 | 300–600 |
| `standard` | `medium` | 預設值：範圍受限的功能、文件、單一模組的測試 | 900–1800 |
| `deep` | `high` | 跨多檔案的修改、難以定位的缺陷、需保持行為的重構 | 1800–3600 |
| `frontier` | `xhigh` | 架構決策、並行與效能問題、需求含糊 | 3600–7200 |

`--tier` 同時設定推理深度與模型。匯出 `CODEX_TIER_<TIER>_MODEL` 即可把某一級綁定到指定模型；未設定的級別使用 Codex 設定檔預設值，`--model` 與 `--effort` 可對單一代理覆寫。`--effort max` 保留給 `frontier` 已在同一問題上失敗兩次的情形。

依難度評級，不依重要性。一次執行中多數工作應落在 `cheap` 與 `standard`；全部都是 `deep` 的執行代表沒有分級。難以判斷時先派 `cheap`，因為失敗的低成本嘗試比不必要的高成本嘗試便宜，而且它的輸出通常能讓重試的規格更精確。

時限是失控保護而非進度表，估算後放大約三倍。大任務配短時限最糟：工作代理在修改到一半被結束，留下半套變更且沒有報告。`--stall` 另外處理無進度的情形，在沒有任何事件超過設定秒數時提前中斷。

並行數由 `codex_capacity.sh` 依核心數、可用記憶體、負載與任務類型（`light`、`medium`、`heavy`）計算，機器繁忙時自動減半，`--per-agent-mb` 可覆寫記憶體估計。混合任務分組計算，並保留餘裕給協調者自己執行的測試。

## 中斷、續作與重新派工

離開碼 124 或 137 表示保護機制結束了工作代理：`meta.json` 的 `timed_out` 或 `stalled` 為真，沒有結果檔，工作區保留當下已完成的修改。`thread.txt` 仍可用，因為 thread id 在執行開始即記錄。

```bash
scripts/codex_agent.sh --run-dir "$RUN" --label auth-cache-cont \
  --resume "$(cat "$RUN/agents/auth-cache/thread.txt")" \
  --cwd /path/to/repo --sandbox workspace-write --effort high --timeout 3600 \
  --prompt-file "$RUN/agents/auth-cache-cont/prompt.md"
```

續作規格說明上一輪被中斷、工作區目前的實際狀態，以及只需完成的剩餘部分。實測：完成五個檔案中的三個時被結束，恢復後從第四個接續。

續作並不便宜。整個 thread 會作為輸入重播，長討論串的一次追問實測超過 30 萬輸入 token。代理數量本身沒有限制，因此判斷依據只有記憶價值。上下文昂貴且仍然正確才續作。上下文小、可從工作區重建，或已被證明錯誤時，改以更精確的規格開新代理，因為錯誤假設會在之後每一輪繼續傳遞。

重試要分類。語義失敗不重送相同提示，改為附上審查證據的定向修正，或重新界定範圍後另派代理。

傳輸失敗屬於另一種情況。Codex 會送出形如 `Reconnecting... n/5 (unexpected status 502 …)` 的非終止 `error` 事件，重試五次後放棄；`meta.json` 記錄 `reconnects` 與 `transient_failure`，狀態表顯示 `TRANSIENT`。任務本身沒有問題，因此不改寫規格，也不靜默重打同一個端點。應立即帶著證據回報使用者——重連次數、端點、供應商的 request id——由使用者決定等待上游恢復，或立刻續作保留下來的 thread。thread id 保存在 `thread.txt`，所以詢問不會損失任何工作。

## 已知限制

- `codex exec` 會讀取繼承而來的 stdin，因此 `codex_agent.sh` 以任務規格檔作為 stdin；手寫呼叫需要 `< /dev/null`。
- `codex exec` 沒有內建時間上限，全部呼叫以 `timeout` 包裝並先送 SIGINT，因為 Codex 會將其轉為正常的回合中斷。
- 全部選項都是根選項，必須放在 `resume` 子命令之前；續作不繼承原本的沙箱、工作目錄、模型與工作區範圍，每次都要重述完整策略。
- `--output-schema` 由 CLI 原樣轉發，錯誤結構只會在付費派工之後被 API 拒絕，因此 `codex_agent.sh` 事先檢查已知的結構化輸出子集。
- 兩個代理寫入同一檔案會互相覆蓋且無法在派工當下偵測，需以 worktree 與 `PLAN.md` 的檔案歸屬預防。

其餘失敗情形見 [references/troubleshooting.md](references/troubleshooting.md)，預設值背後的量測見 [references/evidence.md](references/evidence.md)。

## 文件

- [SKILL.md](SKILL.md)：協調流程
- [references/prompt-template.md](references/prompt-template.md)：任務規格範本
- [references/schemas.md](references/schemas.md)：實作、稽核、研究三類輸出結構
- [references/worktrees.md](references/worktrees.md)：並行寫入隔離、合併與清理
- [references/review-gate.md](references/review-gate.md)：拒絕樂觀判斷的審查流程
- [references/troubleshooting.md](references/troubleshooting.md)：失敗情形與處理方式
- [references/evidence.md](references/evidence.md)：預設值依據的量測與來源

## 授權

MIT
