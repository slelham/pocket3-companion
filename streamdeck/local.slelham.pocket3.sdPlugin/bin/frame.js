const crypto = require("crypto");
const net = require("net");

function encodeFrame(data, opcode) {
  const payload = Buffer.isBuffer(data) ? data : Buffer.from(String(data));
  const mask = crypto.randomBytes(4);
  const masked = Buffer.alloc(payload.length);
  for (let i = 0; i < payload.length; i++) masked[i] = payload[i] ^ mask[i % 4];
  let head;
  if (payload.length < 126) {
    head = Buffer.from([0x80 | opcode, 0x80 | payload.length]);
  } else if (payload.length < 65536) {
    head = Buffer.alloc(4);
    head[0] = 0x80 | opcode;
    head[1] = 0x80 | 126;
    head.writeUInt16BE(payload.length, 2);
  } else {
    throw new Error("frame is too large");
  }
  return Buffer.concat([head, mask, masked]);
}

function Decoder() {
  this.buf = Buffer.alloc(0);
}

Decoder.prototype.take = function (chunk) {
  this.buf = Buffer.concat([this.buf, chunk]);
  const out = [];
  while (this.buf.length >= 2) {
    const opcode = this.buf[0] & 0x0f;
    const masked = (this.buf[1] & 0x80) !== 0;
    let length = this.buf[1] & 0x7f;
    let offset = 2;
    if (length === 126) {
      if (this.buf.length < 4) break;
      length = this.buf.readUInt16BE(2);
      offset = 4;
    } else if (length === 127) {
      break;
    }
    if (this.buf.length < offset + (masked ? 4 : 0) + length) break;
    let payload = this.buf.subarray(offset + (masked ? 4 : 0), offset + (masked ? 4 : 0) + length);
    if (masked) {
      const mask = this.buf.subarray(offset, offset + 4);
      payload = Buffer.from(payload);
      for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4];
    } else {
      payload = Buffer.from(payload);
    }
    this.buf = this.buf.subarray(offset + (masked ? 4 : 0) + length);
    out.push({ opcode, data: payload });
  }
  return out;
};

function connectSocket(port) {
  return new Promise((resolve, reject) => {
    const socket = net.connect({ host: "127.0.0.1", port: Number(port) });
    const key = crypto.randomBytes(16).toString("base64");
    const decoder = new Decoder();
    let handshake = Buffer.alloc(0);
    let open = false;
    let onText = null;
    const pending = [];
    function emit(text) {
      if (onText) onText(text);
      else pending.push(text);
    }
    function feed(chunk) {
      for (const message of decoder.take(chunk)) {
        if (message.opcode === 0x8) socket.end();
        else if (message.opcode === 0x9) socket.write(encodeFrame(message.data, 0x0a));
        else if (message.opcode === 0x1) emit(message.data.toString("utf8"));
      }
    }
    socket.on("data", (chunk) => {
      if (open) {
        feed(chunk);
        return;
      }
      handshake = Buffer.concat([handshake, chunk]);
      const marker = handshake.indexOf("\r\n\r\n");
      if (marker < 0) return;
      const head = handshake.subarray(0, marker).toString("latin1");
      if (!head.includes(" 101 ")) {
        socket.destroy();
        reject(new Error("Stream Deck did not accept the connection"));
        return;
      }
      open = true;
      const rest = handshake.subarray(marker + 4);
      resolve({
        send(text) {
          if (!socket.destroyed) socket.write(encodeFrame(text, 0x1));
        },
        close() {
          socket.end();
        },
        set onText(fn) {
          onText = fn;
          while (pending.length) fn(pending.shift());
        },
      });
      if (rest.length) feed(rest);
    });
    socket.on("error", (error) => {
      if (!open) reject(error);
    });
    socket.on("close", () => {
      if (!open) reject(new Error("connection closed"));
    });
    socket.write(
      "GET / HTTP/1.1\r\n" +
        "Host: 127.0.0.1:" + port + "\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Key: " + key + "\r\n" +
        "Sec-WebSocket-Version: 13\r\n\r\n"
    );
  });
}

module.exports = { encodeFrame, Decoder, connectSocket };
