import { spawn } from "node:child_process";

// Relay self-test, then the Tretu webhook and log format unit tests.
const run = (args) => new Promise((resolve) => {
  const child = spawn(process.execPath, args, { cwd: import.meta.dirname, stdio: "inherit" });
  child.on("exit", (code) => resolve(code ?? 1));
});
const a = await run(["server.mjs", "--self-test"]);
const b = await run(["--test", "--test-reporter=dot", "tretu_webhook.test.mjs", "log.test.mjs"]);
if (b === 0) console.log("tretu webhook + log format tests ok");
process.exit(a || b);
