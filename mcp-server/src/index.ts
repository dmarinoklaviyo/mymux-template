import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import * as net from "net";

const TERMINAL_ID = process.env.MYMUX_TERMINAL_ID;
const SOCKET_PATH = process.env.MYMUX_SOCKET_PATH;

if (!TERMINAL_ID || !SOCKET_PATH) {
  console.error("MYMUX_TERMINAL_ID and MYMUX_SOCKET_PATH must be set");
  process.exit(1);
}

let ipcSocket: net.Socket | null = null;
let reconnectAttempts = 0;
let reqCounter = 0;
const pendingRequests = new Map<
  string,
  { resolve: (v: any) => void; reject: (e: any) => void; timeout: ReturnType<typeof setTimeout> }
>();

function sendIPC(msg: Record<string, unknown>) {
  if (!ipcSocket || ipcSocket.destroyed) return;
  ipcSocket.write(JSON.stringify(msg) + "\n");
}

function sendIPCAndWait(
  msg: Record<string, unknown>,
  timeoutMs = 30000
): Promise<any> {
  return new Promise((resolve, reject) => {
    const req_id = `r${++reqCounter}`;
    msg.req_id = req_id;
    msg.terminal_id = TERMINAL_ID;
    const timeout = setTimeout(() => {
      pendingRequests.delete(req_id);
      reject(new Error("IPC timeout"));
    }, timeoutMs);
    pendingRequests.set(req_id, { resolve, reject, timeout });
    sendIPC(msg);
  });
}

function connectIPC() {
  ipcSocket = net.createConnection(SOCKET_PATH!, () => {
    reconnectAttempts = 0;
    sendIPC({ type: "hello", terminal_id: TERMINAL_ID, version: 1 });
  });

  let buffer = "";
  ipcSocket.on("data", (data) => {
    buffer += data.toString();
    const lines = buffer.split("\n");
    buffer = lines.pop()!;
    for (const line of lines) {
      if (!line.trim()) continue;
      try {
        const msg = JSON.parse(line);
        if (msg.req_id && pendingRequests.has(msg.req_id)) {
          const pending = pendingRequests.get(msg.req_id)!;
          clearTimeout(pending.timeout);
          pendingRequests.delete(msg.req_id);
          pending.resolve(msg);
        }
      } catch {
        // ignore malformed JSON
      }
    }
  });

  ipcSocket.on("error", () => scheduleReconnect());
  ipcSocket.on("close", () => scheduleReconnect());
}

function scheduleReconnect() {
  if (ipcSocket && !ipcSocket.destroyed) return;
  const delay = Math.min(1000 * Math.pow(2, reconnectAttempts++), 10000);
  setTimeout(connectIPC, delay);
}

connectIPC();

const server = new Server(
  { name: "mymux", version: "1.0.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "set_working_directory",
      description:
        "Report the current working directory to mymux. Call this FIRST on every startup.",
      inputSchema: {
        type: "object",
        properties: {
          path: {
            type: "string",
            description: "Absolute path to current working directory",
          },
        },
        required: ["path"],
      },
    },
    {
      name: "log_activity",
      description:
        "Record a timestamped activity milestone in the mymux activity log.",
      inputSchema: {
        type: "object",
        properties: {
          message: {
            type: "string",
            description: "Activity message to log",
          },
        },
        required: ["message"],
      },
    },
    {
      name: "set_terminal_title",
      description:
        "Update this terminal's display name in the mymux sidebar.",
      inputSchema: {
        type: "object",
        properties: {
          title: {
            type: "string",
            description: "New display name",
          },
        },
        required: ["title"],
      },
    },
    {
      name: "notify_user",
      description: "Send a notification to the user via mymux.",
      inputSchema: {
        type: "object",
        properties: {
          message: {
            type: "string",
            description: "Notification message",
          },
          urgency: {
            type: "string",
            enum: ["low", "normal", "critical"],
            description: "Urgency level (default: normal)",
          },
        },
        required: ["message"],
      },
    },
    {
      name: "request_user_input",
      description:
        "Present a native dialog to the user and wait for their response (5 min timeout).",
      inputSchema: {
        type: "object",
        properties: {
          question: {
            type: "string",
            description: "Question to present to the user",
          },
          options: {
            type: "array",
            items: { type: "string" },
            description: "Optional list of button choices (up to 3)",
          },
        },
        required: ["question"],
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    switch (name) {
      case "set_working_directory": {
        const { path } = z.object({ path: z.string() }).parse(args);
        await sendIPCAndWait({ type: "set_working_directory", path });
        return { content: [{ type: "text", text: "Working directory set." }] };
      }
      case "log_activity": {
        const { message } = z.object({ message: z.string() }).parse(args);
        await sendIPCAndWait({ type: "log_activity", message });
        return { content: [{ type: "text", text: "Activity logged." }] };
      }
      case "set_terminal_title": {
        const { title } = z.object({ title: z.string() }).parse(args);
        await sendIPCAndWait({ type: "set_terminal_title", title });
        return { content: [{ type: "text", text: "Title updated." }] };
      }
      case "notify_user": {
        const { message, urgency } = z
          .object({
            message: z.string(),
            urgency: z.enum(["low", "normal", "critical"]).optional(),
          })
          .parse(args);
        await sendIPCAndWait({
          type: "notify_user",
          message,
          urgency: urgency ?? "normal",
        });
        return { content: [{ type: "text", text: "User notified." }] };
      }
      case "request_user_input": {
        const { question, options } = z
          .object({
            question: z.string(),
            options: z.array(z.string()).optional(),
          })
          .parse(args);
        const response = await sendIPCAndWait(
          { type: "request_user_input", question, options },
          310000
        );
        if (response.error) {
          return {
            content: [
              {
                type: "text",
                text: "Timeout: user did not respond within 5 minutes.",
              },
            ],
            isError: true,
          };
        }
        return {
          content: [
            { type: "text", text: response.answer ?? "No answer provided" },
          ],
        };
      }
      default:
        throw new Error(`Unknown tool: ${name}`);
    }
  } catch (e: any) {
    return {
      content: [{ type: "text", text: `Error: ${e.message}` }],
      isError: true,
    };
  }
});

const transport = new StdioServerTransport();
await server.connect(transport);
