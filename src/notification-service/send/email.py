import json
import os
import smtplib
from email.message import EmailMessage


def notification(message):
    """Send the "your audio is ready" email to the user who uploaded the video.

    Returns None on success OR on a deliberate skip (the caller ACKs and moves
    on); returns a truthy error string only for a *retryable* failure (the caller
    NACKs). It never raises — an unhandled exception here crashes the consumer
    pod, which is exactly the CrashLoopBackOff this hardening removes.

    Recipient routing: the message carries `username` (the uploader's email, put
    there by the gateway from the validated JWT and forwarded through the
    converter). This is the standard SaaS "notify the user who triggered the
    action" pattern — the address never comes from a hardcoded value.
    """
    try:
        message = json.loads(message)
    except (ValueError, TypeError) as err:
        # Unparseable body — it will never succeed on retry, so drop it (ACK).
        print(f"notification: dropping unparseable message: {err}")
        return None

    mp3_fid = message.get("mp3_fid")
    receiver_address = message.get("username")

    # Backward compatibility: messages published before per-user routing existed
    # have no `username`. Skip (ACK) rather than crash or loop forever on them.
    if not receiver_address:
        print(f"notification: mp3 {mp3_fid} has no username, skipping email")
        return None

    sender_address = os.environ.get("GMAIL_ADDRESS")
    sender_password = os.environ.get("GMAIL_PASSWORD")

    msg = EmailMessage()
    msg.set_content(
        "Your VidCast audio is ready.\n\n"
        f"File ID: {mp3_fid}\n\n"
        "Download it from the VidCast app using this file ID."
    )
    msg["Subject"] = "Your VidCast audio is ready"
    msg["From"] = sender_address
    msg["To"] = receiver_address

    try:
        session = smtplib.SMTP("smtp.gmail.com", 587)
        session.starttls()
        session.login(sender_address, sender_password)
        session.send_message(msg, sender_address, receiver_address)
        session.quit()
    except Exception as err:
        # Retryable (transient network, or a bad credential that may be fixed by
        # rotating the secret). Returning an error makes the consumer NACK so the
        # message is requeued. NOTE: a *permanently* bad credential will requeue
        # in a loop — in production we'd bound that with a dead-letter queue and a
        # max-retry policy. Deliberately out of scope here (no new infra).
        print(f"notification: failed to send mail for mp3 {mp3_fid}: {err}")
        return f"email send failed: {err}"

    print(f"notification: mail sent to {receiver_address} for mp3 {mp3_fid}")
    return None
