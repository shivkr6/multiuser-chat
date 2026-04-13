module app;

import vibe.core.core;
import vibe.core.concurrency;
import vibe.core.log;
import vibe.http.router : URLRouter;
import vibe.http.server;
import vibe.http.websockets : WebSocket, handleWebSockets;
import core.time;
import std.algorithm : remove;

struct ClientConnected
{
    Tid tid;
}

struct ClientDisconnected
{
    Tid tid;
}

void gameServerTask() nothrow
{
    Tid[] clients;
    try
    {
        while (true)
        {
            receive((string message) {
                logInfo("string message: %s", message);
                foreach (client; clients)
                {
                    client.send(message);
                }

            }, (ClientConnected client) {
                clients ~= client.tid;
                logInfo("new client appended: %s", clients);

            }, (ClientDisconnected client) {
                clients = clients.remove!(c => c == client.tid);
            });
        }
    }
    catch (Exception e)
    {
        logError("Game server task encountered an error: %s", e.msg);
    }
}

void setupWorkerServer(Tid gameServerTid) nothrow
{
    try
    {
        auto router = new URLRouter;
        router.get("/ws", handleWebSockets((WebSocket socket) {
                handleWebSocketConnection(socket, gameServerTid);
            }));

        auto settings = new HTTPServerSettings;
        settings.port = 8080;
        settings.bindAddresses = ["::1", "127.0.0.1"];
        settings.options |= HTTPServerOption.reusePort;

        listenHTTP(settings, router);
    }
    catch (Exception e)
    {
        logError("Failed to start worker server on a thread: %s", e.msg);
    }
}

struct ShutdownWriter
{
}
// Listens to the Game Server, writes to Socket
void socketWriter(WebSocket socket) nothrow
{
    try
    {
        bool running = true;
        while (socket.connected && running)
        {
            receive((string message) { socket.send(message); }, (ShutdownWriter _) {
                running = false;
            });
        }
    }
    catch (Exception e)
    {
        logError("socketWriter failed");
    }
}

// Listens to the Socket, writes to the Game Server
void socketListener(WebSocket socket, Tid gameServer)
{
    try
    {
        while (socket.connected)
        {
            string data = socket.receiveText();
            gameServer.send(data);
        }
    }
    catch (Exception e)
    {
        logError("socketListener failed");
    }
}

void handleWebSocketConnection(scope WebSocket socket, Tid gameServer)
{
    auto writer = runTask(&socketWriter, socket);

    gameServer.send(ClientConnected(writer.tid));

    logInfo("Got new web socket connection.");

    socketListener(socket, gameServer);

    gameServer.send(ClientDisconnected(writer.tid));
    writer.tid.send(ShutdownWriter());

    logInfo("Client disconnected.");
}

int main(string[] args)
{
    auto gameServer = runTask(&gameServerTask);

    runWorkerTaskDist(&setupWorkerServer, gameServer.tid);

    return runApplication(&args);
}
