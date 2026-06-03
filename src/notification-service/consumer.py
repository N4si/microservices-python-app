import os
import pathlib
import sys

import pika
from send import email

def main():
    # rabbitmq connection
    credentials = pika.PlainCredentials(
        os.environ.get("RABBITMQ_DEFAULT_USER", "guest"),
        os.environ.get("RABBITMQ_DEFAULT_PASS", "guest"),
    )
    connection = pika.BlockingConnection(
        pika.ConnectionParameters(host="rabbitmq", credentials=credentials, heartbeat=0)
    )
    channel = connection.channel()

    # Signal readiness as soon as we are connected and ready to consume. The
    # liveness probe checks for this file; without an initial touch an idle
    # consumer would never create it and crash-loop on the probe. This matters
    # especially here: if email delivery fails (e.g. placeholder Gmail
    # password), the per-message touch below never runs, so the startup touch
    # is the only thing keeping the pod alive.
    pathlib.Path("/tmp/healthy").touch()

    def callback(ch, method, properties, body):
        err = email.notification(body)
        if err:
            ch.basic_nack(delivery_tag=method.delivery_tag)
        else:
            ch.basic_ack(delivery_tag=method.delivery_tag)
            pathlib.Path("/tmp/healthy").touch()

    channel.basic_consume(
        queue=os.environ.get("MP3_QUEUE"), on_message_callback=callback
    )

    print("Waiting for messages. To exit press CTRL+C")

    channel.start_consuming()

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("Interrupted")
        try:
            sys.exit(0)
        except SystemExit:
            os._exit(0)