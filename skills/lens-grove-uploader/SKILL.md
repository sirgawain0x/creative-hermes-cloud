---
name: lens-grove-uploader
description: "Upload Mixtape audio, cover art, and editable metadata JSON to Lens Grove on Base Mainnet (8453) with immutable and walletOnly ACLs."
version: 1.0.0
platforms: [linux, macos]
metadata:
  hermes:
    tags: [lens, grove, base, mixtape, audio, ipfs, storage]
    category: media
---

# Lens Grove Uploader Skill

Publish Mixtape audio tracks, cover artwork, and mutable release metadata directly to **Lens Grove** (`@lens-chain/storage-client`) anchored on **Base Mainnet (`8453`)** using the preinstalled `grove-upload` CLI.

> **Strict Guardrail:** Pinata (`PINATA_JWT`) is permanently retired. Never call Pinata APIs or emit `pinata` upload instructions. Standardize every media asset and metadata document on Lens Grove `lens://` URIs.

## Two-Tier Base Mainnet (`8453`) ACL Policy

1. **Audio & Cover Art (`immutable(8453)`)**:
   - Released audio files (`.mp3`, `.wav`, `.flac`, `.ogg`, `.m4a`, `.webm`) and cover artwork (`.png`, `.jpg`, `.webp`) MUST be uploaded with `immutable(8453)` so published media is permanent and tamper-proof.
2. **Track & Mixtape Metadata JSON (`walletOnly(address, 8453)`)**:
   - Track manifests, mixtape playlists, descriptions, tags, and royalty split sheets MUST be uploaded with `walletOnly(artistOrMixtapeWallet, 8453)` so owners can update splits or notes later via `update-json` without breaking the canonical `lens://` URI.

## CLI Reference (`grove-upload`)

All commands emit compact JSON to stdout.

### 1. Upload Audio or Cover Artwork (`immutable(8453)`)

```bash
grove-upload file /path/to/track.mp3 --chain 8453
# -> {"ok":true,"uri":"lens://...","storageKey":"...","gatewayUrl":"https://api.grove.storage/...","acl":"immutable","chainId":8453}
```

### 2. Upload Track or Mixtape Metadata JSON (`walletOnly(address, 8453)`)

```bash
grove-upload json /path/to/metadata.json --wallet 0xArtistOrMixtapeWallet --name mixtape-metadata.json --chain 8453
# or inline JSON:
grove-upload json '{"title":"Late Night Tape","audio":"lens://..."}' --wallet 0xArtistOrMixtapeWallet --name track.json
```

### 3. Update Existing Metadata JSON (`walletOnly(address, 8453)`)

Requires `MIXTAPE_GROVE_SIGNER_KEY` in the runtime environment:

```bash
grove-upload update-json lens://existingStorageKey /path/to/updated.json --wallet 0xArtistOrMixtapeWallet --name mixtape-metadata.json --chain 8453
```

### 4. Resolve a `lens://` URI to an HTTP Gateway URL

```bash
grove-upload resolve lens://yourStorageKey
# -> {"ok":true,"uri":"lens://yourStorageKey","gatewayUrl":"https://api.grove.storage/yourStorageKey"}
```

## Recommended Mixtape Metadata Schema

```json
{
  "schema": "creative-mixtape/v1",
  "title": "Midnight Signal Vol. 1",
  "djPersona": "Velvet Static",
  "description": "Late-night synth and soulful house arc.",
  "audioUri": "lens://...",
  "coverUri": "lens://...",
  "chainId": 8453,
  "tracks": [
    {
      "position": 1,
      "title": "Track Title",
      "artist": "Artist Name",
      "durationSec": 214,
      "audioUri": "lens://...",
      "musicbrainzId": ""
    }
  ],
  "splits": [
    {
      "recipient": "0x...",
      "bps": 10000,
      "role": "primary-artist"
    }
  ]
}
```
