const express = require("express");
const cors = require("cors");
const path = require("path");

const app = express();
const publicRoot = path.join(__dirname);

app.use(cors());
app.use(express.json());
app.use(express.static(publicRoot));

let latestPayload = null;

app.post("/api/drawing", (req, res) => {
  if (!req.body) {
    return res.status(400).json({ error: "No payload provided" });
  }

  latestPayload = {
    ...req.body,
    receivedAt: new Date().toISOString()
  };

  return res.status(204).end();
});

app.get("/api/latest", (req, res) => {
  if (!latestPayload) {
    return res.status(204).end();
  }

  res.status(200).json(latestPayload);
});

app.get("/", (req, res) => {
  res.sendFile(path.join(publicRoot, "mobile-proxy.html"));
});

const port = process.env.PORT || 8080;
app.listen(port, () => {
  /* eslint-disable-next-line no-console */
  console.log(`HandJot proxy server listening on http://localhost:${port}`);
});
