#!/usr/bin/env python3
"""
Tautulli Newsletter to Discord Script
Replaces internal IPs with public domain before posting to Discord
"""
import sys
import json
import requests
import re
import os

# Configuration — set via environment variables or .env
DISCORD_WEBHOOK = os.environ.get("DISCORD_WEBHOOK", "")
INTERNAL_URL = os.environ.get("INTERNAL_URL", "http://localhost:8181")
PUBLIC_URL = os.environ.get("PUBLIC_URL", "https://stats.yourdomain.com")

def main():
    """Main function to process newsletter and send to Discord"""

    # Validate required config
    if not DISCORD_WEBHOOK:
        print("ERROR: DISCORD_WEBHOOK environment variable is not set.")
        print("Export it or add it to your .env file:")
        print("  export DISCORD_WEBHOOK='https://discord.com/api/webhooks/YOUR_ID/YOUR_TOKEN'")
        return 1

    # Get environment variables passed by Tautulli
    newsletter_uuid = os.getenv('tautulli_newsletter_uuid', '')
    newsletter_subject = os.getenv('tautulli_newsletter_subject', 'Newsletter')
    newsletter_body = os.getenv('tautulli_newsletter_body', '')
    tautulli_url = os.getenv('tautulli_url', INTERNAL_URL)

    # Log for debugging
    print(f"Newsletter UUID: {newsletter_uuid}")
    print(f"Newsletter Subject: {newsletter_subject}")
    print(f"Tautulli URL: {tautulli_url}")

    # If we have a newsletter_uuid, construct the URL
    if newsletter_uuid:
        newsletter_url = f"{tautulli_url}/newsletter/{newsletter_uuid}"

        # Replace internal IP with public domain
        public_newsletter_url = newsletter_url.replace(INTERNAL_URL, PUBLIC_URL)

        print(f"Original URL: {newsletter_url}")
        print(f"Public URL: {public_newsletter_url}")

        # Create Discord message
        discord_payload = {
            "content": f"**{newsletter_subject}**\n{public_newsletter_url}"
        }
    else:
        # Fallback: just send the subject
        print("No newsletter UUID provided, sending subject only")
        discord_payload = {
            "content": f"**{newsletter_subject}**"
        }

    # Replace any remaining internal URLs in the body if present
    if newsletter_body:
        newsletter_body = newsletter_body.replace(INTERNAL_URL, PUBLIC_URL)
        discord_payload["content"] += f"\n{newsletter_body[:500]}"  # Limit body length

    # Send to Discord
    try:
        print(f"Sending to Discord...")
        print(f"Payload: {json.dumps(discord_payload, indent=2)}")

        response = requests.post(
            DISCORD_WEBHOOK,
            json=discord_payload,
            headers={"Content-Type": "application/json"},
            timeout=10
        )

        if response.status_code in [200, 204]:
            print("Successfully sent to Discord")
            return 0
        else:
            print(f"Discord returned status {response.status_code}: {response.text}")
            return 1

    except Exception as e:
        print(f"Error sending to Discord: {e}")
        return 1

if __name__ == "__main__":
    sys.exit(main())
