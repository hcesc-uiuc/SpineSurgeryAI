from __future__ import annotations

import os
import json
from contextlib import contextmanager
from typing import Any, Dict, List, Optional, Sequence, Tuple

from dotenv import load_dotenv
import psycopg2
from psycopg2 import sql
from psycopg2.extras import DictCursor, execute_values
from psycopg2.pool import SimpleConnectionPool


# Database class *** Create only 1 instance and reference it
class DB:
    def __init__(
        self,
        database_url_connection_string: Optional[str] = None, # This is just the SQL Database URL
        minimum_connections_in_pool_count: int = 1,
        maximum_connections_in_pool_count: int = 5,
    ):
        load_dotenv()
        self.database_url_connection_string = (
            database_url_connection_string or os.getenv("DATABASE_URL")
        )
        if not self.database_url_connection_string:
            raise RuntimeError(
                "Set DATABASE_URL env var to a URL"
            )
        self.connection_pool_manager: SimpleConnectionPool = SimpleConnectionPool(
            minimum_connections_in_pool_count,
            maximum_connections_in_pool_count,
            dsn=self.database_url_connection_string,
        )

    # ---------------------------
    # Connection helpers
    # ---------------------------
    @contextmanager #borrow  a connection from the pool and return it after done
    def temporary_database_connection(self) -> None:
        database_connection = self.connection_pool_manager.getconn()
        try:
            yield database_connection
        except Exception as database_exception:
            print(f"[DB ERROR] Exception during DB operation: {database_exception}")
            raise
        finally:
            self.connection_pool_manager.putconn(database_connection)

    def close_all_pool_connections(self) -> None:
        self.connection_pool_manager.closeall()

    # ---------------------------
    # Participant helpers
    # ---------------------------

    
    def create_participant_if_missing(self, external_participant_identifier: str) -> int: #Ensure a participant exists and return its internal integer id. If the participant with this external_id does not exist, insert it.

        insert_or_get_participant_sql = (
            "INSERT INTO participants (external_id) VALUES (%s) "
            "ON CONFLICT (external_id) DO UPDATE SET external_id = EXCLUDED.external_id "
            "RETURNING id"
        )
        with self.temporary_database_connection() as database_connection, database_connection.cursor() as database_cursor:
            database_cursor.execute(
                insert_or_get_participant_sql, (external_participant_identifier,)
            )
            participant_id_integer = database_cursor.fetchone()[0]
            return participant_id_integer

    def get_participant_id_if_exists(self, external_participant_identifier: str) -> Optional[int]:
        """Return internal integer id for an external participant id, or None if missing."""
        select_participant_id_sql = (
            "SELECT id FROM participants WHERE external_id = %s"
        )
        with self.temporary_database_connection() as database_connection, database_connection.cursor() as database_cursor:
            database_cursor.execute(
                select_participant_id_sql, (external_participant_identifier,)
            )
            database_row = database_cursor.fetchone()
            return database_row[0] if database_row else None


    # ---------------------------
    # Insert helpers
    # ---------------------------
    @staticmethod
    def normalize_timestamp_to_iso8601(timestamp_value_any: Any) -> str: # DO NOT USE THIS
        """Accept str/datetime/number and return ISO 8601 (Z/offset) string for Postgres TIMESTAMPTZ."""
        import datetime as _dt
        if isinstance(timestamp_value_any, str):
            return timestamp_value_any
        if isinstance(timestamp_value_any, (int, float)):
            return _dt.datetime.utcfromtimestamp(timestamp_value_any).isoformat() + "+00:00"
        if isinstance(timestamp_value_any, _dt.datetime):
            if timestamp_value_any.tzinfo is None:
                timestamp_value_any = timestamp_value_any.replace(tzinfo=_dt.timezone.utc)
            return timestamp_value_any.isoformat()
        raise TypeError(
            "Unsupported timestamp type; use str, datetime, or unix seconds"
        )

    # fix with parser also look at HR 
    def insert_accel(
        self,
        external_participant_identifier: str,
        accelerometer_data_rows_sequence: Sequence[Dict[str, Any] | Tuple[Any, Any, Any, Any]],
    ) -> int:
        #Insert accelerometer rows for a participant.
        #Rows may be dicts {ts, ax, ay, az} or tuples (ts, ax, ay, az).
        #Returns inserted row count.
        
        participant_id_integer = self.create_participant_if_missing(external_participant_identifier)
        accelerometer_payload_rows_list: List[
            Tuple[int, str, Optional[float], Optional[float], Optional[float]]
        ] = []  # (participant_id, iso8601_ts, ax, ay, az)
        for single_accelerometer_record in accelerometer_data_rows_sequence:
            if isinstance(single_accelerometer_record, dict):
                timestamp_iso8601_string = self.normalize_timestamp_to_iso8601(
                    single_accelerometer_record["ts"]
                )
                accelerometer_payload_rows_list.append(
                    (
                        participant_id_integer,
                        timestamp_iso8601_string,
                        single_accelerometer_record.get("ax"),
                        single_accelerometer_record.get("ay"),
                        single_accelerometer_record.get("az"),
                    )
                )
            else:
                timestamp_iso8601_string = self.normalize_timestamp_to_iso8601(
                    single_accelerometer_record[0]
                )
                accelerometer_payload_rows_list.append(
                    (
                        participant_id_integer,
                        timestamp_iso8601_string,
                        single_accelerometer_record[1] if len(single_accelerometer_record) > 1 else None,
                        single_accelerometer_record[2] if len(single_accelerometer_record) > 2 else None,
                        single_accelerometer_record[3] if len(single_accelerometer_record) > 3 else None,
                    )
                )
        if not accelerometer_payload_rows_list:
            return 0
        insert_accelerometer_sql = (
            "INSERT INTO accelerometer (participant_id, ts, ax, ay, az) VALUES %s"
        )
        with self.temporary_database_connection() as database_connection, database_connection.cursor() as database_cursor:
            execute_values(
                database_cursor,
                insert_accelerometer_sql,
                accelerometer_payload_rows_list,
                page_size=1000,
            )
            return database_cursor.rowcount or len(accelerometer_payload_rows_list)

    # fix with parser also look at HR 
    def insert_gyro(
        self,
        external_participant_identifier: str,
        gyroscope_data_rows_sequence: Sequence[Dict[str, Any] | Tuple[Any, Any, Any, Any]],
    ) -> int:
        participant_id_integer = self.create_participant_if_missing(external_participant_identifier)
        gyroscope_payload_rows_list: List[
            Tuple[int, str, Optional[float], Optional[float], Optional[float]]
        ] = []  # (participant_id, iso8601_ts, gx, gy, gz)
        for single_gyroscope_record in gyroscope_data_rows_sequence:
            if isinstance(single_gyroscope_record, dict):
                timestamp_iso8601_string = self.normalize_timestamp_to_iso8601(
                    single_gyroscope_record["ts"]
                )
                gyroscope_payload_rows_list.append(
                    (
                        participant_id_integer,
                        timestamp_iso8601_string,
                        single_gyroscope_record.get("gx"),
                        single_gyroscope_record.get("gy"),
                        single_gyroscope_record.get("gz"),
                    )
                )
            else:
                timestamp_iso8601_string = self.normalize_timestamp_to_iso8601(
                    single_gyroscope_record[0]
                )
                gyroscope_payload_rows_list.append(
                    (
                        participant_id_integer,
                        timestamp_iso8601_string,
                        single_gyroscope_record[1] if len(single_gyroscope_record) > 1 else None,
                        single_gyroscope_record[2] if len(single_gyroscope_record) > 2 else None,
                        single_gyroscope_record[3] if len(single_gyroscope_record) > 3 else None,
                    )
                )
        if not gyroscope_payload_rows_list:
            return 0
        insert_gyroscope_sql = (
            "INSERT INTO gyroscope (participant_id, ts, gx, gy, gz) VALUES %s"
        )
        with self.temporary_database_connection() as database_connection, database_connection.cursor() as database_cursor:
            execute_values(
                database_cursor, insert_gyroscope_sql, gyroscope_payload_rows_list, page_size=1000
            )
            return database_cursor.rowcount or len(gyroscope_payload_rows_list)

    def insert_hr(
        self,
        external_participant_identifier: str,
        heart_rate_data_rows_sequence: Sequence[Dict[str, Any] | Tuple[Any, Any]],
    ) -> int: #returns how many rows inserted
        participant_id_integer = self.create_participant_if_missing(external_participant_identifier)
        heart_rate_payload_rows_list: List[Tuple[int, str, str]] = []  # (participant_id, iso8601_ts, S3 url)
        for single_heart_rate_record in heart_rate_data_rows_sequence:
            if isinstance(single_heart_rate_record, dict):
                timestamp_iso8601_string = self.normalize_timestamp_to_iso8601(
                    single_heart_rate_record["ts"] # timestamp
                )
                object_url_string = single_heart_rate_record.get("url")

            else:
                timestamp_iso8601_string = self.normalize_timestamp_to_iso8601(
                    single_heart_rate_record[0]
                )
                object_url_string = single_heart_rate_record[1] if len(single_heart_rate_record) > 1 else None
            if not object_url_string:
                raise ValueError("heart_rate row missing required 'url' value")

            heart_rate_payload_rows_list.append(
                (participant_id_integer, timestamp_iso8601_string, object_url_string)
            )

        if not heart_rate_payload_rows_list:
            return 0
        insert_heart_rate_sql = (
            "INSERT INTO heart_rate (participant_id, ts, object_url) VALUES %s"
        )
        with self._temporary_database_connection() as database_connection, database_connection.cursor() as database_cursor:
            execute_values(
                database_cursor,
                insert_heart_rate_sql,
                heart_rate_payload_rows_list,
                page_size=1000,
            )
        return database_cursor.rowcount or len(heart_rate_payload_rows_list)

    # fix with parser also look at HR 
    def insert_survey(
        self,
        external_participant_identifier: str,
        survey_date_value_any: Any,
        survey_payload_dictionary: Dict[str, Any],
    ) -> None:
        """Upsert a daily survey JSON by (participant_id, survey_date)."""
        import datetime as _dt
        participant_id_integer = self.create_participant_if_missing(external_participant_identifier)
        if isinstance(survey_date_value_any, str):
            survey_date_iso8601_string = survey_date_value_any
        elif isinstance(survey_date_value_any, _dt.date):
            survey_date_iso8601_string = survey_date_value_any.isoformat()
        else:
            raise TypeError("survey_date must be date or ISO string")
        upsert_daily_survey_sql = (
            "INSERT INTO daily_survey (participant_id, survey_date, payload) "
            "VALUES (%s, %s, %s) "
            "ON CONFLICT (participant_id, survey_date) DO UPDATE SET payload = EXCLUDED.payload"
        )
        with self.temporary_database_connection() as database_connection, database_connection.cursor() as database_cursor:
            database_cursor.execute(
                upsert_daily_survey_sql,
                (
                    participant_id_integer,
                    survey_date_iso8601_string,
                    json.dumps(survey_payload_dictionary),
                ),
            )

    # ---------------------------
    # Refresh presence MVs & simple reads
    # ---------------------------
    def refresh_summary_cache(self, use_concurrent_refresh: bool = True) -> None: # Use after flask push insert data then refresh
        #Refresh all daily presence materialized views. If concurrent refresh fails (e.g., first population), falls back automatically.
        
        refresh_all_materialized_views_sql_template = (
            "REFRESH MATERIALIZED VIEW {mode} mv_accel_daily_presence;"
            "REFRESH MATERIALIZED VIEW {mode} mv_gyro_daily_presence;"
            "REFRESH MATERIALIZED VIEW {mode} mv_hr_daily_presence;"
            "REFRESH MATERIALIZED VIEW {mode} mv_survey_daily_presence;"
        )

        def execute_refresh_with_mode(mode_clause_string: str) -> None:
            refresh_statement_sql = refresh_all_materialized_views_sql_template.format(
                mode=mode_clause_string
            )
            with self.temporary_database_connection() as database_connection, database_connection.cursor() as database_cursor:
                database_cursor.execute(refresh_statement_sql)
                database_connection.commit()

        try:
            if use_concurrent_refresh:
                execute_refresh_with_mode("CONCURRENTLY ")
            else:
                execute_refresh_with_mode("")
        except Exception:
            execute_refresh_with_mode("")

    def get_dashboard(
        self,
        external_participant_identifier_list: Optional[Sequence[str]] = None,
        maximum_row_count_limit: Optional[int] = None,
    ) -> List[Dict[str, Any]]:
        """Return rows from v_compliance_dashboard as list of dicts.
        Optionally filter by external_participant_identifier_list and/or limit row count.
        """
        select_dashboard_base_sql = "SELECT * FROM v_compliance_dashboard"
        sql_parameter_values_list: List[Any] = []
        where_clause_strings_list: List[str] = []
        if external_participant_identifier_list:
            placeholders_comma_separated_string = ",".join(
                ["%s"] * len(external_participant_identifier_list)
            )
            where_clause_strings_list.append(
                f"external_id IN ({placeholders_comma_separated_string})"
            )
            sql_parameter_values_list.extend(list(external_participant_identifier_list))
        if where_clause_strings_list:
            select_dashboard_base_sql += " WHERE " + " AND ".join(
                where_clause_strings_list
            )
        select_dashboard_base_sql += " ORDER BY participant_id"
        if maximum_row_count_limit:
            select_dashboard_base_sql += " LIMIT %s"
            sql_parameter_values_list.append(maximum_row_count_limit)
        with self.temporary_database_connection() as database_connection, database_connection.cursor(cursor_factory=DictCursor) as database_cursor:
            database_cursor.execute(
                select_dashboard_base_sql, sql_parameter_values_list
            )
            return [dict(row) for row in database_cursor.fetchall()]

    def get_last7_strips(self, external_participant_identifier: str) -> Optional[Dict[str, Any]]:
        """Return the strip arrays for a single participant from v_last7_strips."""
        select_last7_strips_sql = (
            "SELECT ls.* FROM v_last7_strips ls "
            "JOIN participants p ON p.id = ls.participant_id "
            "WHERE p.external_id = %s"
        )
        with self.temporary_database_connection() as database_connection, database_connection.cursor(cursor_factory=DictCursor) as database_cursor:
            database_cursor.execute(select_last7_strips_sql, (external_participant_identifier,))
            row = database_cursor.fetchone()
            return dict(row) if row else None

    def get_compliance_for(self, external_participant_identifier: str) -> Dict[str, Any]:
        """Return a compact compliance dict for accel/gyro/hr/survey for one participant."""
        select_compliance_sql = """
            SELECT p.external_id,
                   ac.days_3  AS accel_days_3, ac.days_7  AS accel_days_7, ac.meets_1_of_3 AS accel_1of3, ac.meets_4_of_7 AS accel_4of7,
                   gc.days_3  AS gyro_days_3,  gc.days_7  AS gyro_days_7,  gc.meets_1_of_3 AS gyro_1of3,  gc.meets_4_of_7 AS gyro_4of_7,
                   hc.days_3  AS hr_days_3,    hc.days_7  AS hr_days_7,    hc.meets_1_of_3 AS hr_1of3,    hc.meets_4_of_7 AS hr_4of_7,
                   sc.days_3  AS survey_days_3,sc.days_7  AS survey_days_7,sc.meets_1_of_3 AS survey_1of_3,sc.meets_4_of_7 AS survey_4_of_7
            FROM participants p
            LEFT JOIN v_accel_compliance ac  ON ac.participant_id = p.id
            LEFT JOIN v_gyro_compliance  gc  ON gc.participant_id = p.id
            LEFT JOIN v_hr_compliance    hc  ON hc.participant_id = p.id
            LEFT JOIN v_survey_compliance sc ON sc.participant_id = p.id
            WHERE p.external_id = %s
        """
        with self.temporary_database_connection() as database_connection, database_connection.cursor(cursor_factory=DictCursor) as database_cursor:
            database_cursor.execute(select_compliance_sql, (external_participant_identifier,))
            row = database_cursor.fetchone()
            return dict(row) if row else {}

    # ---------------------------
    # Simple presence queries (raw)
    # ---------------------------
    def get_presence_counts(
        self,
        presence_materialized_view_table_name: str,
        external_participant_identifier: str,
        lookback_days_count_integer: int = 7,
    ) -> List[Tuple[str, int]]:
        """Generic helper over mv_*_daily_presence to get (day, points/forms) for last N days.
        `presence_materialized_view_table_name` should be one of: mv_accel_daily_presence,
        mv_gyro_daily_presence, mv_hr_daily_presence, mv_survey_daily_presence.
        Returns list of (YYYY-MM-DD, count) sorted by day.
        """
        if presence_materialized_view_table_name not in {
            "mv_accel_daily_presence",
            "mv_gyro_daily_presence",
            "mv_hr_daily_presence",
            "mv_survey_daily_presence",
        }:
            raise ValueError("Invalid presence table name")
        presence_counts_query_sql = sql.SQL(
            """
            SELECT d.day::text, COALESCE(pcnt, 0) AS count
            FROM generate_series(current_date - %s::int * INTERVAL '1 day' + INTERVAL '1 day',
                                 current_date,
                                 '1 day') AS d(day)
            LEFT JOIN (
                SELECT m.day, COUNT(*) AS pcnt
                FROM {mv} m
                JOIN participants p ON p.id = m.participant_id
                WHERE p.external_id = %s AND m.day >= current_date - %s::int * INTERVAL '1 day' + INTERVAL '1 day'
                GROUP BY m.day
            ) s ON s.day = d.day
            ORDER BY d.day
            """
        ).format(mv=sql.Identifier(presence_materialized_view_table_name))
        with self.temporary_database_connection() as database_connection, database_connection.cursor() as database_cursor:
            database_cursor.execute(
                presence_counts_query_sql,
                (
                    lookback_days_count_integer,
                    external_participant_identifier,
                    lookback_days_count_integer,
                ),
            )
            return [
                (row_tuple[0], row_tuple[1]) for row_tuple in database_cursor.fetchall()
            ]

    # ---------------------------
    # Deletion helpers (for tests)
    # ---------------------------
    def delete_participant(self, external_participant_identifier: str) -> int:
        """Delete a participant by external_id. Returns number of rows deleted (0/1)."""
        delete_participant_sql = (
            "DELETE FROM participants WHERE external_id = %s RETURNING id"
        )
        with self.temporary_database_connection() as database_connection, database_connection.cursor() as database_cursor:
            database_cursor.execute(
                delete_participant_sql, (external_participant_identifier,)
            )
            return database_cursor.rowcount or 0

    def truncate_data(self) -> None:
        """Dangerous: wipe all timeseries & surveys (keeps participants)."""
        truncate_all_timeseries_sql = (
            "TRUNCATE accelerometer, gyroscope, heart_rate, daily_survey RESTART IDENTITY CASCADE;"
        )
        with self.temporary_database_connection() as database_connection, database_connection.cursor() as database_cursor:
            database_cursor.execute(truncate_all_timeseries_sql)
            database_connection.commit()

db = DB()

# Create or ensure a participant exists
participant_id = db.create_participant_if_missing("P0001")

# Insert some dummy accelerometer data
db.insert_accel("P0001", [
    {"ts": "2025-10-06T12:00:00Z", "ax": 0.1, "ay": 0.0, "az": -0.2},
    {"ts": "2025-10-06T12:00:01Z", "ax": 0.2, "ay": 0.1, "az": -0.1},
])

# Refresh presence materialized views
db.refresh_summary_cache()

# Get dashboard rows
print(db.get_dashboard())