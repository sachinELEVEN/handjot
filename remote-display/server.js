const http = require("http");
const express = require("express");
const cors = require("cors");
const path = require("path");
const WebSocket = require("ws");

const app = express();
const publicRoot = path.join(__dirname);

app.use(cors());
app.use(express.json());
app.use(express.static(publicRoot));

const server = http.createServer(app);
const wss = new WebSocket.Server({ server, path: "/ws" });

let latestPayload = null;
const clients = new Set();

function broadcast(payload) {
  const payloadString = JSON.stringify(payload);
  for (const client of clients) {
    if (client.readyState === WebSocket.OPEN) {
      client.send(payloadString);
    }
  }
}

wss.on("connection", (ws) => {
  clients.add(ws);
  if (latestPayload) {
    ws.send(JSON.stringify(latestPayload));
  }

  ws.on("message", (data) => {
    try {
      const message = JSON.parse(data);
      if (message.action === "publish" && message.payload) {
        latestPayload = {
          ...message.payload,
          receivedAt: new Date().toISOString()
        };
        broadcast(latestPayload);
      } else if (message.action === "fetch" && latestPayload) {
        ws.send(JSON.stringify(latestPayload));
      }
    } catch (error) {
      console.warn("Invalid websocket payload", error);
    }
  });

  const cleanup = () => clients.delete(ws);
  ws.on("close", cleanup);
  ws.on("error", cleanup);
});

app.get("/", (req, res) => {
  res.sendFile(path.join(publicRoot, "mobile-proxy.html"));
});

const port = process.env.PORT || 8080;
server.listen(port, () => {
  console.log(`HandJot proxy server listening on http://localhost:${port}`);
});
