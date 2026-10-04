import { spawn } from "node:child_process";

const child = spawn(process.execPath, ["server.mjs", "--self-test"], { cwd: import.meta.dirname, stdio: "inherit" });
child.on("exit", (code) => process.exit(code ?? 1));
