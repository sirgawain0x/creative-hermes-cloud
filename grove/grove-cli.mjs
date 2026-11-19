#!/usr/bin/env node
import { File as BufferFile } from "node:buffer";
import fs from "node:fs";
import path from "node:path";
import { StorageClient, immutable, walletOnly } from "@lens-chain/storage-client";
import { getAddress } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const FileImpl = globalThis.File ?? BufferFile;

const MIME_BY_EXT = {
  ".mp3": "audio/mpeg",
  ".wav": "audio/wav",
  ".flac": "audio/flac",
  ".ogg": "audio/ogg",
  ".opus": "audio/ogg",
  ".m4a": "audio/mp4",
  ".mp4": "audio/mp4",
  ".webm": "audio/webm",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".webp": "image/webp",
  ".gif": "image/gif",
  ".json": "application/json",
};

function parseArgs(argv) {
  const positional = [];
  const flags = {};
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (token.startsWith("--")) {
      const key = token.slice(2);
      const next = argv[i + 1];
      if (next !== undefined && !next.startsWith("--")) {
        flags[key] = next;
        i += 1;
      } else {
        flags[key] = "true";
      }
    } else {
      positional.push(token);
    }
  }
  return { positional, flags };
}

function parseChainId(raw) {
  const chainId = Number(raw ?? "8453");
  if (!Number.isInteger(chainId) || chainId <= 0) {
    throw new Error(`Invalid --chain value: ${raw}`);
  }
  return chainId;
}

function readJsonInput(arg) {
  if (!arg) {
    throw new Error("Missing JSON file path or inline JSON argument");
  }
  if (fs.existsSync(arg) && fs.statSync(arg).isFile()) {
    return JSON.parse(fs.readFileSync(arg, "utf8"));
  }
  return JSON.parse(arg);
}

function inferMimeType(filePath) {
  const ext = path.extname(filePath).toLowerCase();
  return MIME_BY_EXT[ext] ?? "application/octet-stream";
}

function normalizePrivateKey(raw) {
  const trimmed = String(raw || "").trim();
  if (!trimmed) {
    throw new Error("MIXTAPE_GROVE_SIGNER_KEY environment variable is required for update-json");
  }
  return trimmed.startsWith("0x") ? trimmed : `0x${trimmed}`;
}

async function main() {
  const [command, ...rest] = process.argv.slice(2);
  if (!command || command === "--help" || command === "-h") {
    console.error(
      "Usage:\n" +
        "  grove-upload file <filePath> [--chain 8453]\n" +
        "  grove-upload json <filePathOrJson> --wallet <0xAddress> [--name metadata.json] [--chain 8453]\n" +
        "  grove-upload update-json <uriOrKey> <filePathOrJson> [--wallet <0xAddress>] [--name metadata.json] [--chain 8453]\n" +
        "  grove-upload resolve <uriOrKey>",
    );
    process.exit(command ? 0 : 1);
  }

  const { positional, flags } = parseArgs(rest);
  const client = StorageClient.create();

  if (command === "file") {
    const filePath = positional[0];
    if (!filePath || !fs.existsSync(filePath)) {
      throw new Error(`File not found: ${filePath || "(missing)"}`);
    }
    const chainId = parseChainId(flags.chain);
    const bytes = fs.readFileSync(filePath);
    const fileName = path.basename(filePath);
    const mimeType = inferMimeType(filePath);
    const file = new FileImpl([bytes], fileName, { type: mimeType });
    const res = await client.uploadFile(file, { acl: immutable(chainId) });
    console.log(
      JSON.stringify({
        ok: true,
        uri: res.uri,
        storageKey: res.storageKey,
        gatewayUrl: res.gatewayUrl,
        acl: "immutable",
        chainId,
      }),
    );
    return;
  }

  if (command === "json") {
    const inputArg = positional[0];
    if (!flags.wallet) {
      throw new Error("--wallet <0xAddress> is required for json upload");
    }
    const wallet = getAddress(flags.wallet);
    const chainId = parseChainId(flags.chain);
    const name = flags.name || "metadata.json";
    const data = readJsonInput(inputArg);
    const res = await client.uploadAsJson(data, {
      acl: walletOnly(wallet, chainId),
      name,
    });
    console.log(
      JSON.stringify({
        ok: true,
        uri: res.uri,
        storageKey: res.storageKey,
        gatewayUrl: res.gatewayUrl,
        acl: "walletOnly",
        wallet,
        chainId,
      }),
    );
    return;
  }

  if (command === "update-json") {
    const [uriOrKey, inputArg] = positional;
    if (!uriOrKey) {
      throw new Error("Missing <uriOrKey> for update-json");
    }
    const chainId = parseChainId(flags.chain);
    const name = flags.name || "metadata.json";
    const account = privateKeyToAccount(normalizePrivateKey(process.env.MIXTAPE_GROVE_SIGNER_KEY));
    const wallet = getAddress(flags.wallet || account.address);
    const data = readJsonInput(inputArg);
    const signer = {
      signMessage: ({ message }) => account.signMessage({ message }),
    };
    const res = await client.updateJson(uriOrKey, data, signer, {
      acl: walletOnly(wallet, chainId),
      name,
    });
    console.log(
      JSON.stringify({
        ok: true,
        uri: res.uri,
        storageKey: res.storageKey,
        gatewayUrl: res.gatewayUrl,
        updated: true,
        wallet,
        chainId,
      }),
    );
    return;
  }

  if (command === "resolve") {
    const uriOrKey = positional[0];
    if (!uriOrKey) {
      throw new Error("Missing <uriOrKey> for resolve");
    }
    const gatewayUrl = client.resolve(uriOrKey);
    console.log(
      JSON.stringify({
        ok: true,
        uri: uriOrKey,
        gatewayUrl,
      }),
    );
    return;
  }

  throw new Error(`Unknown subcommand: ${command}`);
}

main().catch((err) => {
  console.error(JSON.stringify({ ok: false, error: err?.message || String(err) }));
  process.exit(1);
});
