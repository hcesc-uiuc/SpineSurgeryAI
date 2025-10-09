from models.data_record import db, DataRecord

def save_record(filename, s3_link):
    record = DataRecord(filename=filename, s3_link=s3_link)
    db.session.add(record)
    db.session.commit()