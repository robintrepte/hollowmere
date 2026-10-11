# Let an AI play Hollowmere

An MCP (Model Context Protocol) helper can watch your farm or play as you — or as a virtual farmhand — while the game stays open. The world is simulated **in your game client**. The hosted relay only forwards commands.

You can use Claude Desktop, Claude.ai (custom connector), Claude Code, Cursor, or any MCP client.

## 1. In the game

1. Sign in.
2. Load a farm (you host).
3. Press **O** → **Set up a helper** (or Koop → AI helpers).
4. Copy the address. Create a token and copy it (it is shown only once). **Copy for Cursor** pastes a ready-made config.
5. Optional:
   - **Let a helper play** — you watch. **I'll play** gives you the farmer back.
   - **Invite** — up to 3 farmhands (`agent:1` …). Copy the id and pass it as `actor`.

Keep the tab visible in a browser. Background tabs pause the simulation.

## 2. Cursor / Claude Code (personal token)

Add a server that talks Streamable HTTP to `https://mcp.hollowmere.tretu.de/mcp` (or your own host).

```json
{
  "mcpServers": {
    "hollowmere": {
      "url": "https://mcp.hollowmere.tretu.de/mcp",
      "headers": { "Authorization": "Bearer hm_YOUR_TOKEN" }
    }
  }
}
```

For a local stack: `http://127.0.0.1:8787/mcp` and the same Bearer header.

## 3. Claude.ai custom connector (OAuth)

1. In Claude, add a custom connector pointing at `https://mcp.hollowmere.tretu.de`.
2. Dynamic client registration lives at `POST /register`.
3. The authorize page asks you to paste a token from the game.
4. Claude then calls `/mcp` with the issued access token.

## 4. What the helper can do

**See:** status (including the held item), look around (JSON + ASCII map), inventory and hotbar, party, farm, quests, shop, battle, dialogue (with choices), chat.

**Do:** select an item, walk, use tools, plant / water / harvest areas, ship, craft, jobs, chat (a bubble and the farm log), emotes, sleep, farm routine, continue or choose dialogue, battles, enchant, casino (economy scope).

**Never:** delete a save. Selling items worth 200g or more needs the **economy** scope.

Prompts the client can load: `farmer`, `coop_partner`, `battle_grind`, `optimize_farm`.

## 5. Privacy

Tokens are hashed on the server. Revoke them in the agent panel. Command logs stay in Nakama storage only long enough to return a result. See `store/TERMS.md`.

## 6. Run the relay yourself

```bash
cd server
docker compose up -d mcp
# health: curl http://127.0.0.1:8787/health
node mcp/server.mjs --self-test
```

Point nginx at `127.0.0.1:8787` for `mcp.$DOMAIN` (see HOSTING.md).
