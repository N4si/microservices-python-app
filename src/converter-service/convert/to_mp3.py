import json
import os
import tempfile

import pika
from bson.objectid import ObjectId
import moviepy.editor

def start(message, fs_videos, fs_mp3s, channel):
    message = json.loads(message)

    # empty temp file
    tf = tempfile.NamedTemporaryFile()
    # video content
    out = fs_videos.get(ObjectId(message["video_fid"]))
    # add video content to temp file
    tf.write(out.read())
    # create audio from temp video file
    audio = moviepy.editor.VideoFileClip(tf.name).audio
    tf.close()

    # write audio to the file
    tf_path = tempfile.gettempdir() + f"/{message['video_fid']}.mp3"
    audio.write_audiofile(tf_path)

    # save the file to the mongodb database. Copy the owner tag from the video
    # message onto the mp3 so /my-files and the unseen-count badge can find it;
    # .get() keeps backward-compat with old messages that have no username.
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
        return "failed to publish message"
