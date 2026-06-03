import json

import pika


def upload(f, fs, channel, access):
    try:
        # Tag the stored video with its owner (the uploader's JWT email) and a
        # filename. owner_email is what /my-files and the unseen-count badge
        # query on; the converter copies the same tag onto the resulting mp3.
        fid = fs.put(
            f,
            filename=getattr(f, "filename", None),
            metadata={"owner_email": access["username"]},
        )
    except Exception as err:
        print(err)
        return "internal server error, fs level", 500

    message = {
        "video_fid": str(fid),
        "mp3_fid": None,
        "username": access["username"],
    }

    try:
        channel.basic_publish(
            exchange="",
            routing_key="video",
            body=json.dumps(message),
            properties=pika.BasicProperties(
                delivery_mode=pika.spec.PERSISTENT_DELIVERY_MODE
            ),
        )
    except Exception as err:
        print(err)
        fs.delete(fid)
        return f"internal server error rabbitmq issue, {err}", 500
