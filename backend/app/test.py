from database.database import DB
# db = DB()
# db.refresh_summary_cache()
# print(db.get_presence_counts("mv_accel_daily_presence", "P0001", 7))
# # db.truncate_data()


db = DB()

with db.temporary_database_connection() as conn, conn.cursor() as cur:
    cur.execute("SELECT id, external_id FROM participants ORDER BY id;")
    print(cur.fetchall())

with db.temporary_database_connection() as conn, conn.cursor() as cur:
    cur.execute("""
        SELECT d.day::text, COALESCE(pcnt, 0) AS count
        FROM generate_series(current_date - %s::int * INTERVAL '1 day' + INTERVAL '1 day',
                             current_date,
                             '1 day') AS d(day)
        LEFT JOIN (
            SELECT m.day, COUNT(*) AS pcnt
            FROM mv_accel_daily_presence m
            JOIN participants p ON p.id = m.participant_id
            WHERE p.external_id = %s
              AND m.day >= current_date - %s::int * INTERVAL '1 day' + INTERVAL '1 day'
            GROUP BY m.day
        ) s ON s.day = d.day
        ORDER BY d.day;
    """, (7, "P0001", 7))
    print(cur.fetchall())
