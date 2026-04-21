import "dotenv/config";
import { createApp } from "./app.js";
import { migrate, pool } from "./db.js";

const port = Number(process.env.PORT ?? 3000);
const corsOrigin = process.env.CORS_ORIGIN ?? "*";
const apiKey = process.env.API_KEY?.trim() || undefined;

async function main() {
    await migrate();
    const app = createApp({ corsOrigin, apiKey });

    const server = app.listen(port, () => {
        console.log(`lifting API listening on http://localhost:${port}`);
        if (!apiKey) {
            console.log("API_KEY not set -- auth is disabled (dev mode).");
        }
    });

    const shutdown = async (signal: string) => {
        console.log(`\n${signal} received, shutting down...`);
        server.close(() => {
            void pool.end().then(() => process.exit(0));
        });
        setTimeout(() => process.exit(1), 10_000).unref();
    };

    process.on("SIGINT", () => void shutdown("SIGINT"));
    process.on("SIGTERM", () => void shutdown("SIGTERM"));
}

main().catch((err) => {
    console.error("Failed to start lifting API", err);
    process.exit(1);
});
