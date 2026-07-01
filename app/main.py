# Minimal Flask app for Mini Deploy Platform V2.
# Returns 200 on / so the ALB health check passes.

from flask import Flask

app = Flask(__name__)


@app.route("/")
def index():
    return "Mini Deploy Platform — V2 OK. Adding one more to line to check with lambda", 200


@app.route("/health")
def health():
    return "OK", 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)
