import SillHostMain

// 真正的启动代码在 Sources/SillHostMain/SillHostMain.swift（runSillHostCLI），
// 融合 app 以 `--host-mode` 重入自己时跑的是同一份。
runSillHostCLI()
