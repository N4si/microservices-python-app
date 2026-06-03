import os
import pathlib
import sys

import pika
from pymongo import MongoClient
import gridfs
from convert import to_mp3

def main():
    client = MongoClient(os.environ.get('MONGODB_URI'))
    db_videos = client.videos
    db_mp3s = client.mp3s
    # gridfs
    fs_videos = gridfs.GridFS(db_videos)
    fs_mp3s = gridfs.GridFS(db_mp3s)

    # rabbitmq connection
    credentials = pika.PlainCredentials(
        os.environ.get("RABBITMQ_DEFAULT_USER", "guest"),
        os.environ.get("RABBITMQ_DEFAULT_PASS", "guest"),
    )
    connection = pika.BlockingConnection(
        pika.ConnectionParameters(host='rabbitmq', credentials=credentials, heartbeat=0)
    )
    channel = connection.channel()

    # Signal readiness as soon as we are connected and ready to consume. The
    # liveness probe checks for this file; without an initial touch an idle
    # consumer (no messages yet) would never create it and crash-loop on the
    # probe. Each successfully processed message refreshes it below.
    pathlib.Path("/tmp/healthy").touch()

    def callback(ch, method, properties, body):
        err = to_mp3.start(body, fs_videos, fs_mp3s, ch)
        if err:
            ch.basic_nack(delivery_tag=method.delivery_tag)
        else:
            ch.basic_ack(delivery_tag=method.delivery_tag)
            pathlib.Path("/tmp/healthy").touch()

    channel.basic_consume(
        queue=os.environ.get("VIDEO_QUEUE"), on_message_callback=callback
    )

    print("Waitting for messages, to exit press CTRL+C")

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
