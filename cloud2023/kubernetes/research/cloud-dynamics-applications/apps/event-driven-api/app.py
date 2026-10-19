from flask import Flask, jsonify, request
import os, time, json, uuid
import redis, pika, pg8000

app = Flask(__name__)
role = os.getenv("ROLE", "api")

r = None
rmq = None
db = None

def get_redis():
    global r
    if r is None:
        r = redis.Redis(host=os.getenv("REDIS_HOST", "redis"), port=6379, db=0, decode_responses=True)
    return r

def get_rmq():
    global rmq
    if rmq is None or rmq.is_closed:
        params = pika.ConnectionParameters(host=os.getenv("RMQ_HOST", "rabbitmq"), heartbeat=600, blocked_connection_timeout=300)
        rmq = pika.BlockingConnection(params)
    return rmq

def get_db():
    global db
    if db is None:
        db = pg8000.connect(
            user=os.getenv("DB_USER", "postgres"),
            password=os.getenv("DB_PASS", "postgres"),
            host=os.getenv("DB_HOST", "postgres"),
            port=5432,
            database=os.getenv("DB_NAME", "postgres")
        )
    return db

@app.route("/", methods=["GET", "POST"])
def index():
    if role == "api":
        order_id = str(uuid.uuid4())
        cache = get_redis()
        cache.set(f"order:{order_id}", "pending")
        
        mq = get_rmq()
        channel = mq.channel()
        channel.queue_declare(queue='order_queue', durable=True)
        channel.basic_publish(
            exchange='',
            routing_key='order_queue',
            body=json.dumps({"order_id": order_id, "timestamp": time.time()}),
            properties=pika.BasicProperties(delivery_mode=pika.spec.PERSISTENT_DELIVERY_MODE)
        )
        return jsonify(status="accepted", order_id=order_id), 202

    return jsonify(error="Not API"), 400

@app.route("/health")
def health(): return "ok\n"

@app.route("/metrics")
def metrics(): return f'app_info{{application="event-driven-api",role="{role}"}} 1\n', 200, {"Content-Type": "text/plain"}

def worker_loop():
    print("Starting worker loop")
    mq = get_rmq()
    channel = mq.channel()
    channel.queue_declare(queue='order_queue', durable=True)
    
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute("CREATE TABLE IF NOT EXISTS orders (id VARCHAR(50) PRIMARY KEY, status VARCHAR(20), created_at FLOAT)")
    conn.commit()

    def callback(ch, method, properties, body):
        try:
            data = json.loads(body)
            conn = get_db()
            cursor = conn.cursor()
            cursor.execute("INSERT INTO orders (id, status, created_at) VALUES (%s, %s, %s)", (data["order_id"], "processed", data["timestamp"]))
            conn.commit()
            
            # Simulate CPU work to make worker the bottleneck
            work = int(os.getenv("WORK_CYCLES", "5000"))
            for i in range(work):
                _ = i * i
            
            ch.basic_ack(delivery_tag=method.delivery_tag)
        except Exception as e:
            print("Error processing message:", e)
            ch.basic_nack(delivery_tag=method.delivery_tag, requeue=True)

    channel.basic_qos(prefetch_count=1)
    channel.basic_consume(queue='order_queue', on_message_callback=callback)
    try:
        channel.start_consuming()
    except KeyboardInterrupt:
        channel.stop_consuming()

if __name__ == "__main__":
    if role == "api":
        app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8080")), threaded=True)
    elif role == "worker":
        while True:
            try:
                worker_loop()
            except Exception as e:
                print("Worker error:", e)
                time.sleep(5)
