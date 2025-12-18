from database.database import DB

db = DB()
print(db.get_table("gyroscope"))