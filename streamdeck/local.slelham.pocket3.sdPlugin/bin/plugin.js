const fs = require("fs");
const http = require("http");
const os = require("os");
const path = require("path");
const { connectSocket } = require("./frame");

const pairPath = path.join(os.homedir(), "Library", "Application Support", "Pocket3 Companion", "streamdeck.json");

const moves = {
  left: { pan: -1, tilt: 0, name: "Left" },
  right: { pan: 1, tilt: 0, name: "Right" },
  up: { pan: 0, tilt: 1, name: "Up" },
  down: { pan: 0, tilt: -1, name: "Down" },
  upLeft: { pan: -1, tilt: 1, name: "Up left" },
  upRight: { pan: 1, tilt: 1, name: "Up right" },
  downLeft: { pan: -1, tilt: -1, name: "Down left" },
  downRight: { pan: 1, tilt: -1, name: "Down right" },
};

function argument(flag) {
  const index = process.argv.indexOf(flag);
  return index >= 0 ? process.argv[index + 1] : "";
}

function pairing() {
  try {
    const data = JSON.parse(fs.readFileSync(pairPath, "utf8"));
    if (!data.token || !data.port) return null;
    return { token: String(data.token), port: Number(data.port) };
  } catch (error) {
    return null;
  }
}

function call(method, urlPath, body) {
  const pair = pairing();
  if (!pair) return Promise.resolve(null);
  const payload = body ? JSON.stringify(body) : null;
  return new Promise((resolve) => {
    const request = http.request(
      {
        host: "127.0.0.1",
        port: pair.port,
        method,
        path: urlPath,
        timeout: 1500,
        headers: {
          Authorization: "Bearer " + pair.token,
          "Content-Type": "application/json",
          ...(payload ? { "Content-Length": Buffer.byteLength(payload) } : {}),
        },
      },
      (response) => {
        const chunks = [];
        response.on("data", (chunk) => chunks.push(chunk));
        response.on("end", () => {
          resolve({ status: response.statusCode, body: Buffer.concat(chunks).toString("utf8") });
        });
      }
    );
    request.on("error", () => resolve(null));
    request.on("timeout", () => {
      request.destroy();
      resolve(null);
    });
    if (payload) request.write(payload);
    request.end();
  });
}

const actions = new Map();
const inspectors = new Set();
const titles = new Map();
let presets = [];
let offline = true;
let socket = null;

function send(message) {
  if (socket) socket.send(JSON.stringify(message));
}

function showAlert(context) {
  send({ event: "showAlert", context });
}

function setTitle(context, title) {
  if (titles.get(context) === title) return;
  titles.set(context, title);
  send({ event: "setTitle", context, payload: { title, target: 0 } });
}

function remember(data) {
  const settings = (data.payload && data.payload.settings) || {};
  actions.set(data.context, { action: data.action, settings });
  return settings;
}

function presetNamed(id) {
  if (!id) return null;
  return presets.find((item) => item.id.toLowerCase() === String(id).toLowerCase()) || null;
}

function labelFor(info) {
  const action = info.action || "";
  const settings = info.settings || {};
  if (action.endsWith(".recall")) {
    if (!settings.presetId) return "Preset";
    const found = presetNamed(settings.presetId);
    if (offline) return found ? found.name : "Preset";
    return found ? found.name : "Missing";
  }
  if (action.endsWith(".move")) return (moves[settings.direction] || moves.left).name;
  if (action.endsWith(".zoom")) return settings.direction === "out" ? "Zoom out" : "Zoom in";
  if (action.endsWith(".recenter")) return "Center";
  if (action.endsWith(".stop")) return "Stop";
  return "";
}

function refreshTitles() {
  for (const [context, info] of actions) setTitle(context, labelFor(info));
}

function sendPresets(context) {
  const info = actions.get(context);
  send({
    event: "sendToPropertyInspector",
    context,
    payload: {
      presets,
      offline,
      presetId: info && info.settings.presetId ? info.settings.presetId : "",
      direction: info && info.settings.direction ? info.settings.direction : "",
    },
  });
}

async function refresh() {
  const response = await call("GET", "/v1/presets");
  if (!response || response.status !== 200) {
    offline = true;
  } else {
    try {
      const data = JSON.parse(response.body);
      presets = (data.presets || [])
        .filter((item) => item && !item.empty && item.id)
        .map((item) => ({ id: String(item.id), name: String(item.name || "Preset") }));
      offline = false;
    } catch (error) {
      offline = true;
    }
  }
  refreshTitles();
  for (const context of inspectors) sendPresets(context);
}

async function onDown(data) {
  const settings = remember(data);
  const action = data.action || "";
  const context = data.context;
  if (action.endsWith(".recall")) {
    const found = presetNamed(settings.presetId);
    if (!settings.presetId || !found) {
      showAlert(context);
      return;
    }
    const response = await call("POST", "/v1/presets/recall/" + found.id);
    let body = {};
    try {
      body = JSON.parse((response && response.body) || "{}");
    } catch (error) {
      body = {};
    }
    if (!response || response.status !== 200 || body.noop) showAlert(context);
    return;
  }
  if (action.endsWith(".move")) {
    const move = moves[settings.direction] || moves.left;
    const response = await call("POST", "/v1/hold", { id: context, pan: move.pan, tilt: move.tilt, zoom: 0 });
    if (!response || response.status !== 200) showAlert(context);
    return;
  }
  if (action.endsWith(".zoom")) {
    const zoom = settings.direction === "out" ? -1 : 1;
    const response = await call("POST", "/v1/hold", { id: context, pan: 0, tilt: 0, zoom });
    if (!response || response.status !== 200) showAlert(context);
    return;
  }
  if (action.endsWith(".recenter")) {
    const response = await call("POST", "/v1/recenter");
    if (!response || response.status !== 200) showAlert(context);
    return;
  }
  if (action.endsWith(".stop")) {
    const response = await call("POST", "/v1/stop");
    if (!response || response.status !== 200) showAlert(context);
  }
}

async function onUp(context) {
  await call("POST", "/v1/release", { id: context });
}

function onMessage(text) {
  let data;
  try {
    data = JSON.parse(text);
  } catch (error) {
    return;
  }
  switch (data.event) {
    case "willAppear":
    case "didReceiveSettings":
      remember(data);
      setTitle(data.context, labelFor(actions.get(data.context)));
      break;
    case "willDisappear":
      actions.delete(data.context);
      titles.delete(data.context);
      onUp(data.context).catch(() => {});
      break;
    case "keyDown":
      onDown(data).catch(() => showAlert(data.context));
      break;
    case "keyUp":
      onUp(data.context).catch(() => {});
      break;
    case "propertyInspectorDidAppear":
      inspectors.add(data.context);
      sendPresets(data.context);
      break;
    case "propertyInspectorDidDisappear":
      inspectors.delete(data.context);
      break;
    case "sendToPlugin":
      sendPresets(data.context);
      break;
    default:
      break;
  }
}

async function main() {
  const port = argument("-port");
  const uuid = argument("-pluginUUID");
  const registerEvent = argument("-registerEvent") || "registerPlugin";
  socket = await connectSocket(port);
  socket.onText = onMessage;
  socket.send(JSON.stringify({ event: registerEvent, uuid }));
  await refresh();
  setInterval(() => {
    refresh().catch(() => {});
  }, 2000);
}

main().catch((error) => {
  console.error(error && error.message ? error.message : error);
  process.exit(1);
});
