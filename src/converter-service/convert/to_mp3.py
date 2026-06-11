import json
import os
import tempfile

import pika
from bson.objectid import ObjectId
import moviepy.editor

def start(message, fs_videos, fs_mp3s, channel):
    message = json.loads(message)

    tf = tempfile.NamedTemporaryFile()
    out = fs_videos.get(ObjectId(message["video_fid"]))
    tf.write(out.read())
    audio = moviepy.editor.VideoFileClip(tf.name).audio
    tf.close()

    tf_path = tempfile.gettempdir() + f"/{message['video_fid']}.mp3"
    audio.write_audiofile(tf_path)

    # Carry owner_email from the video onto the mp3 so /my-files finds it; .get()
    # tolerates older messages with no username.
    f = open(tf_path, "rb")
    data = f.read()
    fid = fs_mp3s.put(
        data,
        filename=f"{message['video_fid']}.mp3",
        metadata={"owner_email": message.get("username")},
    )
    f.close()
    os.remove(tf_path)

    message["mp3_fid"] = str(fid)

    try:
        channel.basic_publish(
            exchange="",
            routing_key=os.environ.get("MP3_QUEUE"),
            body=json.dumps(message),
            properties=pika.BasicProperties(
                delivery_mode=pika.spec.PERSISTENT_DELIVERY_MODE
            ),
        )
    except Exception:
        fs_mp3s.delete(fid)
        return None, "failed to publish message"

    # Hand back the mp3 id + size for the consumer to record as the ready status.
    return {"mp3_fid": str(fid), "mp3_size": len(data)}, None
