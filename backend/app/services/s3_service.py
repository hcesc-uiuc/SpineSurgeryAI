import boto3
from flask import current_app

def upload_to_s3(file_content, filename):
    s3 = boto3.client(
        "s3",
        aws_access_key_id=current_app.config["AWS_ACCESS_KEY_ID"],
        aws_secret_access_key=current_app.config["AWS_SECRET_ACCESS_KEY"]
    )
    bucket = current_app.config["S3_BUCKET"]
    s3.put_object(Bucket=bucket, Key=filename, Body=file_content)
    return f"s3://{bucket}/{filename}"