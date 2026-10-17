import os, json, time, logging
from datetime import datetime, timezone
import boto3, pymysql
from flask import Flask, render_template, request, redirect, url_for, flash
from werkzeug.utils import secure_filename
logging.basicConfig(level=logging.INFO)
log=logging.getLogger('portal')
app=Flask(__name__); app.secret_key=os.environ.get('FLASK_SECRET_KEY','lab-only-change-before-production')
REGION=os.environ.get('AWS_REGION','us-east-1'); BUCKET=os.environ['DOCUMENTS_BUCKET']; DB_HOST=os.environ['DB_HOST']; DB_NAME=os.environ.get('DB_NAME','insurance'); SECRET_ARN=os.environ['DB_SECRET_ARN']
s3=boto3.client('s3',region_name=REGION); sm=boto3.client('secretsmanager',region_name=REGION)
def connect_db():
    secret=json.loads(sm.get_secret_value(SecretId=SECRET_ARN)['SecretString'])
    return pymysql.connect(host=DB_HOST,user=secret['username'],password=secret['password'],database=DB_NAME,connect_timeout=5,read_timeout=10,write_timeout=10,cursorclass=pymysql.cursors.DictCursor,autocommit=True)
def ensure_table(c):
    with c.cursor() as cur:
        cur.execute('''CREATE TABLE IF NOT EXISTS policies (id BIGINT AUTO_INCREMENT PRIMARY KEY, customer_name VARCHAR(120) NOT NULL, policy_number VARCHAR(80) NOT NULL UNIQUE, insurance_type VARCHAR(80) NOT NULL, coverage_amount DECIMAL(14,2) NOT NULL, document_key VARCHAR(1024) NOT NULL, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)''')
def init_db():
    for attempt in range(12):
        try:
            c=connect_db()
            try:
                with c.cursor() as cur: cur.execute('''CREATE TABLE IF NOT EXISTS policies (id BIGINT AUTO_INCREMENT PRIMARY KEY, customer_name VARCHAR(120) NOT NULL, policy_number VARCHAR(80) NOT NULL UNIQUE, insurance_type VARCHAR(80) NOT NULL, coverage_amount DECIMAL(14,2) NOT NULL, document_key VARCHAR(1024) NOT NULL, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)''')
            finally: c.close()
            log.info('Database table ready'); return
        except Exception: log.exception('DB initialization attempt %s failed',attempt+1); time.sleep(min((attempt+1)*5,20))
    log.error('DB initialization retries exhausted')
@app.get('/health')
def health(): return {'status':'ok'},200
@app.get('/')
def index():
    rows=[]; err=None
    try:
        c=connect_db()
        try:
            ensure_table(c)
            with c.cursor() as cur: cur.execute('SELECT id,customer_name,policy_number,insurance_type,coverage_amount,created_at FROM policies ORDER BY id DESC LIMIT 20'); rows=cur.fetchall()
        finally: c.close()
    except Exception: log.exception('Unable to load policies'); err='Database unavailable. Check ECS logs, RDS security group and DB secret.'
    return render_template('index.html',policies=rows,db_error=err)
@app.post('/policies')
def create_policy():
    name=request.form.get('customer_name','').strip(); number=request.form.get('policy_number','').strip(); kind=request.form.get('insurance_type','').strip(); raw=request.form.get('coverage_amount','').strip(); upload=request.files.get('document')
    if not all([name,number,kind,raw,upload]): flash('Complete every field and select a document.','error'); return redirect(url_for('index'))
    try:
        amount=float(raw)
        if amount<=0: raise ValueError()
    except ValueError: flash('Coverage must be a positive number.','error'); return redirect(url_for('index'))
    filename=secure_filename(upload.filename or ''); ext=filename.rsplit('.',1)[-1].lower() if '.' in filename else ''
    if ext not in {'pdf','jpg','jpeg','png'}: flash('Allowed files: PDF, JPG, JPEG, PNG.','error'); return redirect(url_for('index'))
    body=upload.read(10*1024*1024+1)
    if not body or len(body)>10*1024*1024: flash('Choose a non-empty file no larger than 10 MB.','error'); return redirect(url_for('index'))
    key=f"policy-documents/{datetime.now(timezone.utc):%Y/%m}/{int(time.time())}-{filename}"
    try: s3.put_object(Bucket=BUCKET,Key=key,Body=body,ContentType=upload.mimetype or 'application/octet-stream',ServerSideEncryption='AES256')
    except Exception: log.exception('S3 upload failed'); flash('S3 upload failed. Check task-role permissions and logs.','error'); return redirect(url_for('index'))
    try:
        c=connect_db()
        try:
            ensure_table(c)
            with c.cursor() as cur: cur.execute('INSERT INTO policies (customer_name,policy_number,insurance_type,coverage_amount,document_key) VALUES (%s,%s,%s,%s,%s)',(name,number,kind,amount,key))
        finally: c.close()
    except Exception:
        log.exception('DB save failed')
        try: s3.delete_object(Bucket=BUCKET,Key=key)
        except Exception: log.exception('Cleanup of uploaded object failed')
        flash('Database save failed. Check RDS settings and ECS logs.','error'); return redirect(url_for('index'))
    flash('Policy saved and document uploaded successfully.','success'); return redirect(url_for('index'))
if __name__=='__main__': app.run(host='0.0.0.0',port=8080)
