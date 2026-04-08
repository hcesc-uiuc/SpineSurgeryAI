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
            database_connection.autocommit = True # autocommit can be put manually for other stuff
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

    def insert_accel(
        self,
        external_participant_identifier: str,
        accelerometer_data_rows_sequence: Sequence[Dict[str, Any] | Tuple[Any, Any]],
    ) -> int:
        """Insert accelerometer objects (timestamp + URL). Returns inserted row count.

        Accepts rows as:
        - dict: {"url": <str>, "ts": <str/datetime/unix> (optional, defaults to placeholder)}
        - tuple: (<url>,) or (<ts>, <url>)
        
        If ts is not provided, it defaults to Unix epoch (1970-01-01) as a placeholder.
        The checker will later update ts to the actual recording time from the data file.
        """
        # Placeholder timestamp - obviously wrong so it's clear the checker hasn't processed it yet
        PLACEHOLDER_TS = "1970-01-01T00:00:00+00:00"
        
        participant_id_integer = self.create_participant_if_missing(external_participant_identifier)
        accelerometer_payload_rows_list: List[Tuple[int, str, str]] = []  # (participant_id, iso8601_ts, url)

        for single_accel_record in accelerometer_data_rows_sequence:
            if isinstance(single_accel_record, dict):
                object_url_string = single_accel_record.get("url")
                # ts is optional - default to placeholder if not provided
                if "ts" in single_accel_record:
                    timestamp_iso8601_string = self.normalize_timestamp_to_iso8601(single_accel_record["ts"])
                else:
                    timestamp_iso8601_string = PLACEHOLDER_TS
            else:
                # For tuples, check length to determine format
                if len(single_accel_record) == 1:
                    # Just URL provided
                    object_url_string = single_accel_record[0]
                    timestamp_iso8601_string = PLACEHOLDER_TS
                else:
                    # (ts, url) format
                    timestamp_iso8601_string = self.normalize_timestamp_to_iso8601(single_accel_record[0])
                    object_url_string = single_accel_record[1]

            if not object_url_string:
                raise ValueError("accelerometer row missing required 'url' value")

            accelerometer_payload_rows_list.append(
                (participant_id_integer, timestamp_iso8601_string, object_url_string)
            )

        if not accelerometer_payload_rows_list:
            return 0

        insert_accelerometer_sql = (
            "INSERT INTO accelerometer (participant_id, ts, object_url) VALUES %s"
        )
        with self.temporary_database_connection() as database_connection, database_connection.cursor() as database_cursor:
            execute_values(
                database_cursor,
                insert_accelerometer_sql,
                accelerometer_payload_rows_list,
                page_size=1000,
            )
        return database_cursor.rowcount or len(accelerometer_payload_rows_list)


    def insert_gyro(
        self,
        external_participant_identifier: str,
        gyroscope_data_rows_sequence: Sequence[Dict[str, Any] | Tuple[Any, Any]],
    ) -> int:
        """Insert gyroscope objects (timestamp + URL). Returns inserted row count.

        Accepts rows as:
        - dict: {"url": <str>, "ts": <str/datetime/unix> (optional, defaults to placeholder)}
        - tuple: (<url>,) or (<ts>, <url>)
        
        If ts is not provided, it defaults to Unix epoch (1970-01-01) as a placeholder.
        The checker will later update ts to the actual recording time from the data file.
        """
        # Placeholder timestamp - obviously wrong so it's clear the checker hasn't processed it yet
        PLACEHOLDER_TS = "1970-01-01T00:00:00+00:00"
        
        participant_id_integer = self.create_participant_if_missing(external_participant_identifier)
        gyroscope_payload_rows_list: List[Tuple[int, str, str]] = []  # (participant_id, iso8601_ts, S3/HTTP url)

        for single_gyroscope_record in gyroscope_data_rows_sequence:
            if isinstance(single_gyroscope_record, dict):
                object_url_string = single_gyroscope_record.get("url")
                # ts is optional - default to placeholder if not provided
                if "ts" in single_gyroscope_record:
                    timestamp_iso8601_string = self.normalize_timestamp_to_iso8601(single_gyroscope_record["ts"])
                else:
                    timestamp_iso8601_string = PLACEHOLDER_TS
            else:
                # For tuples, check length to determine format
                if len(single_gyroscope_record) == 1:
                    # Just URL provided
                    object_url_string = single_gyroscope_record[0]
                    timestamp_iso8601_string = PLACEHOLDER_TS
                else:
                    # (ts, url) format
                    timestamp_iso8601_string = self.normalize_timestamp_to_iso8601(single_gyroscope_record[0])
                    object_url_string = single_gyroscope_record[1]

            if not object_url_string:
                raise ValueError("gyroscope row missing required 'url' value")

            gyroscope_payload_rows_list.append(
                (participant_id_integer, timestamp_iso8601_string, object_url_string)
            )

        if not gyroscope_payload_rows_list:
            return 0

        insert_gyroscope_sql = (
            "INSERT INTO gyroscope (participant_id, ts, object_url) VALUES %s"
        )
        with self.temporary_database_connection() as database_connection, database_connection.cursor() as database_cursor:
            execute_values(
                database_cursor,
                insert_gyroscope_sql,
                gyroscope_payload_rows_list,
                page_size=1000,
            )
        return database_cursor.rowcount or len(gyroscope_payload_rows_list)

    def insert_hr(
        self,
        external_participant_identifier: str,
        heart_rate_data_rows_sequence: Sequence[Dict[str, Any] | Tuple[Any, Any]],
    ) -> int:
        """Insert heart rate objects (timestamp + URL). Returns inserted row count.

        Accepts rows as:
        - dict: {"url": <str>, "ts": <str/datetime/unix> (optional, defaults to placeholder)}
        - tuple: (<url>,) or (<ts>, <url>)
        
        If ts is not provided, it defaults to Unix epoch (1970-01-01) as a placeholder.
        The checker will later update ts to the actual recording time from the data file.
        """
        # Placeholder timestamp - obviously wrong so it's clear the checker hasn't processed it yet
        PLACEHOLDER_TS = "1970-01-01T00:00:00+00:00"
        
        participant_id_integer = self.create_participant_if_missing(external_participant_identifier)
        heart_rate_payload_rows_list: List[Tuple[int, str, str]] = []  # (participant_id, iso8601_ts, S3 url)
        
        for single_heart_rate_record in heart_rate_data_rows_sequence:
            if isinstance(single_heart_rate_record, dict):
                object_url_string = single_heart_rate_record.get("url")
                # ts is optional - default to placeholder if not provided
                if "ts" in single_heart_rate_record:
                    timestamp_iso8601_string = self.normalize_timestamp_to_iso8601(single_heart_rate_record["ts"])
                else:
                    timestamp_iso8601_string = PLACEHOLDER_TS
            else:
                # For tuples, check length to determine format
                if len(single_heart_rate_record) == 1:
                    # Just URL provided
                    object_url_string = single_heart_rate_record[0]
                    timestamp_iso8601_string = PLACEHOLDER_TS
                else:
                    # (ts, url) format
                    timestamp_iso8601_string = self.normalize_timestamp_to_iso8601(single_heart_rate_record[0])
                    object_url_string = single_heart_rate_record[1]
                    
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
        with self.temporary_database_connection() as database_connection, database_connection.cursor() as database_cursor:
            execute_values(
                database_cursor,
                insert_heart_rate_sql,
                heart_rate_payload_rows_list,
                page_size=1000,
            )
        return database_cursor.rowcount or len(heart_rate_payload_rows_list)

    def insert_survey(
    self,
    external_participant_identifier: str,
    survey_data_rows_sequence: Sequence[Dict[str, Any] | Tuple[Any, ...]],
    ) -> int:
        """
        Insert survey rows (date + URL + optional payload) for a participant.

        Each row can be:
        - dict: {"survey_date": <str/date>, "url": <str>, "payload": <dict or JSON-serializable, optional>}
        - tuple: (<survey_date>, <url>, <payload_optional>)

        Upserts on (participant_id, survey_date) like before.
        """
        import datetime as _dt

        participant_id_integer = self.create_participant_if_missing(
            external_participant_identifier
        )

        survey_payload_rows_list: List[Tuple[int, str, str, str]] = []  # (participant_id, survey_date_iso, object_url, payload_json)

        for single_survey_record in survey_data_rows_sequence:
            # ----- dict style -----
            if isinstance(single_survey_record, dict):
                raw_date = single_survey_record["survey_date"]
                object_url_string = single_survey_record.get("url")
                payload_obj = single_survey_record.get("payload", {})
            # ----- tuple style -----
            else:
                raw_date = single_survey_record[0]
                object_url_string = single_survey_record[1] if len(single_survey_record) > 1 else None
                payload_obj = single_survey_record[2] if len(single_survey_record) > 2 else {}

            # normalize survey_date to YYYY-MM-DD
            if isinstance(raw_date, str):
                survey_date_iso8601_string = raw_date
            elif isinstance(raw_date, _dt.date):
                survey_date_iso8601_string = raw_date.isoformat()
            else:
                raise TypeError("survey_date must be date or ISO string")

            if not object_url_string:
                raise ValueError("survey row missing required 'url' (object_url) value")

            survey_payload_rows_list.append(
                (
                    participant_id_integer,
                    survey_date_iso8601_string,
                    object_url_string,
                    json.dumps(payload_obj),
                )
            )

        if not survey_payload_rows_list:
            return 0

        upsert_daily_survey_sql = """
            INSERT INTO daily_survey (
                participant_id,
                survey_date,
                object_url,
                payload
            )
            VALUES %s
            ON CONFLICT (participant_id, survey_date)
            DO UPDATE SET
                object_url = EXCLUDED.object_url,
                payload    = EXCLUDED.payload
        """

        with self.temporary_database_connection() as database_connection, database_connection.cursor() as database_cursor:
            execute_values(
                database_cursor,
                upsert_daily_survey_sql,
                survey_payload_rows_list,
                page_size=1000,
            )
            return database_cursor.rowcount or len(survey_payload_rows_list)

    # Writes metrics about data ingestion health, sent db
    def insert_ingestion_health(
        self,
        modality: str,
        external_participant_identifier: str,
        window_start: Any,
        window_end: Any,
        analysis: Dict[str, Any],
        status: Optional[str] = None,
    ) -> None:
        """
        Insert or update ingestion health record for a participant/modality/window.

        `analysis` is the dict returned by analyze_uploaded_data(...), e.g.:

        {
            "format": "csv",
            "row_count": 90000,
            "sampling_rate_hz": 100.0,
            "expected_samples": 90000,
            "actual_samples": 87000,
            "completeness": 0.966,
            "total_gap_seconds": 2.5,
            "gap_fraction": 0.0027,
            "is_usable": True,
        }
        """

        participant_id_integer = self.create_participant_if_missing(
            external_participant_identifier
        )

        expected_samples = int(analysis.get("expected_samples", 0))
        actual_samples = int(analysis.get("actual_samples", 0))
        completeness = float(analysis.get("completeness", 0.0))

        pct_expected = completeness * 100.0 if expected_samples > 0 else 0.0

        # If caller didn't pass explicit status, derive from is_usable
        if status is None:
            is_usable_flag = bool(analysis.get("is_usable", False))
            status = "OK" if is_usable_flag else "LOW"

        upsert_sql = """
            INSERT INTO ingestion_health (
                modality, participant_id, window_start, window_end,
                expected_count, actual_count, pct_expected, status,
                format, row_count, sampling_rate_hz,
                completeness, total_gap_seconds, gap_fraction, is_usable
            )
            VALUES (%s, %s, %s, %s,
                    %s, %s, %s, %s,
                    %s, %s, %s,
                    %s, %s, %s, %s)
            ON CONFLICT (modality, participant_id, window_start)
            DO UPDATE SET
                actual_count      = EXCLUDED.actual_count,
                expected_count    = EXCLUDED.expected_count,
                pct_expected      = EXCLUDED.pct_expected,
                status            = EXCLUDED.status,
                format            = EXCLUDED.format,
                row_count         = EXCLUDED.row_count,
                sampling_rate_hz  = EXCLUDED.sampling_rate_hz,
                completeness      = EXCLUDED.completeness,
                total_gap_seconds = EXCLUDED.total_gap_seconds,
                gap_fraction      = EXCLUDED.gap_fraction,
                is_usable         = EXCLUDED.is_usable,
                updated_at        = now();
        """

        with self.temporary_database_connection() as conn, conn.cursor() as cur:
            cur.execute(
                upsert_sql,
                (
                    modality,
                    participant_id_integer,
                    window_start,
                    window_end,
                    expected_samples,
                    actual_samples,
                    pct_expected,
                    status,
                    analysis.get("format"),
                    int(analysis.get("row_count", 0)),
                    float(analysis.get("sampling_rate_hz", 0.0)),
                    float(analysis.get("completeness", 0.0)),
                    float(analysis.get("total_gap_seconds", 0.0)),
                    float(analysis.get("gap_fraction", 1.0)),
                    bool(analysis.get("is_usable", False)),
                ),
            )

    # ---------------------------
    # Update helpers
    # ---------------------------
    def update_recording_timestamp(
        self,
        kind: str,
        row_id: int,
        recording_timestamp_iso: str,
    ) -> bool:
        """
        Update the ts field for a timeseries row to reflect the actual recording time
        (extracted from the uploaded data file).
        
        Args:
            kind: "accel", "gyro", or "hr"
            row_id: The database row id to update
            recording_timestamp_iso: ISO 8601 timestamp string of when data was actually recorded
            
        Returns:
            True if update succeeded, False otherwise
        """
        # Map kind to table name
        table_map = {
            "accel": "accelerometer",
            "gyro": "gyroscope",
            "hr": "heart_rate",
        }
        
        table_name = table_map.get(kind)
        if not table_name:
            raise ValueError(f"Unknown kind: {kind}. Expected 'accel', 'gyro', or 'hr'")
        
        update_sql = sql.SQL(
            "UPDATE {table} SET ts = %s WHERE id = %s"
        ).format(table=sql.Identifier(table_name))
        
        with self.temporary_database_connection() as conn, conn.cursor() as cur:
            cur.execute(update_sql, (recording_timestamp_iso, row_id))
            return cur.rowcount > 0

    def refresh_summary_cache(self, use_concurrent_refresh: bool = True) -> None:
        views = [
            "mv_accel_daily_presence",
            "mv_gyro_daily_presence",
            "mv_hr_daily_presence",
            "mv_survey_daily_presence",
        ]

        def do_refresh(mode: str):
            for view in views:
                stmt = f"REFRESH MATERIALIZED VIEW {mode}{view};"
                with self.temporary_database_connection() as conn, conn.cursor() as cur:
                    cur.execute(stmt)

        if use_concurrent_refresh:
            try:
                do_refresh("CONCURRENTLY ")
            except Exception:
                do_refresh("")
        else:
            do_refresh("")
    # rewrite this 
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

    # returns whether or not their is data from the last 7 days (1 is yes data, 0 is no their is no data) -> reads from summary cache
    def get_last_7_days(self, external_participant_identifier: str) -> Optional[Dict[str, Any]]: 
        select_last_7_days_sql = (
            "SELECT ls.* FROM v_last7_strips ls "
            "JOIN participants p ON p.id = ls.participant_id "
            "WHERE p.external_id = %s"
        )
        with self.temporary_database_connection() as database_connection, database_connection.cursor(cursor_factory=DictCursor) as database_cursor:
            database_cursor.execute(select_last_7_days_sql, (external_participant_identifier,))
            row = database_cursor.fetchone()
            return dict(row) if row else None

    def get_compliance_for(self, external_participant_identifier: str) -> Dict[str, Any]: # let postgres handle compliance, Return a compact compliance dict for accel/gyro/hr/survey for one participant
        select_compliance_sql = """
            SELECT p.external_id,
                ac.days_3  AS accel_days_3, ac.days_7  AS accel_days_7, ac.meets_1_of_3 AS accel_1of3, ac.meets_4_of_7 AS accel_4of7,
                gc.days_3  AS gyro_days_3,  gc.days_7  AS gyro_days_7,  gc.meets_1_of_3 AS gyro_1of3,  gc.meets_4_of_7 AS gyro_4of_7,
                hc.days_3  AS hr_days_3,    hc.days_7  AS hr_days_7,    hc.meets_1_of_3 AS hr_1of3,    hc.meets_4_of_7 AS hr_4of_7,
                sc.days_3  AS survey_days_3, sc.days_7  AS survey_days_7,sc.meets_1_of_3 AS survey_1of_3,sc.meets_4_of_7 AS survey_4_of_7
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

    def get_table(self, table_name: str) -> list[dict]: # gets all rows from a table
        # Prevent SQL injection by validating table name
        allowed_tables = {"accelerometer", "gyroscope", "heart_rate", "daily_survey", "participants", "ingestion_health"}
        if table_name not in allowed_tables:
            raise ValueError(f"Table '{table_name}' not allowed.")

        query = f"SELECT * FROM {table_name};"
        with self.temporary_database_connection() as conn, conn.cursor(cursor_factory=DictCursor) as cur:
            cur.execute(query)
            return [dict(row) for row in cur.fetchall()]

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
    def delete_participant(self, external_participant_identifier: str) -> int: #Delete a participant by external_id. Returns number of rows deleted (0/1)
        delete_participant_sql = (
            "DELETE FROM participants WHERE external_id = %s RETURNING id"
        )
        with self.temporary_database_connection() as database_connection, database_connection.cursor() as database_cursor:
            database_cursor.execute(
                delete_participant_sql, (external_participant_identifier,)
            )
            return database_cursor.rowcount or 0

    def truncate_data(self) -> None: #Dangerous: wipe all timeseries & surveys (keeps participants)
        truncate_all_timeseries_sql = (
            "TRUNCATE accelerometer, gyroscope, heart_rate, daily_survey RESTART IDENTITY CASCADE;"
        )
        with self.temporary_database_connection() as database_connection, database_connection.cursor() as database_cursor:
            database_cursor.execute(truncate_all_timeseries_sql)
            database_connection.commit()

    # adds file size of the upload
    def update_file_size(self, kind: str, row_id: int, file_size_megabytes: int) -> bool:
        table_map = {"accel": "accelerometer", "gyro": "gyroscope", "hr": "heart_rate"}
        table_name = table_map.get(kind)
        if not table_name:
            raise ValueError(f"Unknown kind: {kind}")

        update_sql = sql.SQL("UPDATE {table} SET file_size_bytes = %s WHERE id = %s").format(
            table=sql.Identifier(table_name)
        )
        with self.temporary_database_connection() as database_connection:
            with database_connection.cursor() as database_cursor:
                database_cursor.execute(update_sql, (file_size_megabytes, row_id))

    # ---------------------------
    # Auth helpers
    # ---------------------------
    def create_users_table(self) -> None:
        """Create the users table if it doesn't exist."""
        sql_text = """
        CREATE TABLE IF NOT EXISTS users (
            id          SERIAL PRIMARY KEY,
            apple_id    TEXT UNIQUE NOT NULL,
            email       TEXT,
            full_name   TEXT
        );
        """
        with self.temporary_database_connection() as conn, conn.cursor() as cur:
            cur.execute(sql_text)

    def create_refresh_tokens_table(self) -> None:
        """Create the refresh_tokens table if it doesn't exist."""
        sql_text = """
        CREATE TABLE IF NOT EXISTS refresh_tokens (
            id          SERIAL PRIMARY KEY,
            user_id     INTEGER NOT NULL REFERENCES users(id),
            token_hash  TEXT UNIQUE NOT NULL,
            expires_at  TIMESTAMP WITH TIME ZONE NOT NULL,
            revoked     BOOLEAN DEFAULT FALSE
        );
        """
        with self.temporary_database_connection() as conn, conn.cursor() as cur:
            cur.execute(sql_text)

    def get_user_by_apple_id(self, apple_id: str) -> Optional[Dict[str, Any]]:
        """Return user dict (id, apple_id, email, full_name) or None if not found."""
        sql_text = "SELECT id, apple_id, email, full_name FROM users WHERE apple_id = %s"
        with self.temporary_database_connection() as conn, conn.cursor(cursor_factory=DictCursor) as cur:
            cur.execute(sql_text, (apple_id,))
            row = cur.fetchone()
            return dict(row) if row else None

    def create_user(self, apple_id: str, email: Optional[str], full_name: Optional[str]) -> Dict[str, Any]:
        """Insert a new user and return dict with id."""
        sql_text = (
            "INSERT INTO users (apple_id, email, full_name) VALUES (%s, %s, %s) RETURNING id, apple_id, email, full_name"
        )
        with self.temporary_database_connection() as conn, conn.cursor(cursor_factory=DictCursor) as cur:
            cur.execute(sql_text, (apple_id, email, full_name))
            return dict(cur.fetchone())

    def create_refresh_token(self, user_id: int, token_hash: str, expires_at: Any) -> None:
        """Insert a refresh token record (stores SHA-256 hash, not raw token)."""
        sql_text = "INSERT INTO refresh_tokens (user_id, token_hash, expires_at) VALUES (%s, %s, %s)"
        with self.temporary_database_connection() as conn, conn.cursor() as cur:
            cur.execute(sql_text, (user_id, token_hash, expires_at))

    def get_refresh_token_by_hash(self, token_hash: str) -> Optional[Dict[str, Any]]:
        """Return refresh token record dict (user_id, revoked, expires_at) or None."""
        sql_text = "SELECT id, user_id, token_hash, expires_at, revoked FROM refresh_tokens WHERE token_hash = %s"
        with self.temporary_database_connection() as conn, conn.cursor(cursor_factory=DictCursor) as cur:
            cur.execute(sql_text, (token_hash,))
            row = cur.fetchone()
            return dict(row) if row else None

    def revoke_refresh_token(self, token_hash: str) -> None:
        """Mark a refresh token as revoked by its hash."""
        sql_text = "UPDATE refresh_tokens SET revoked = TRUE WHERE token_hash = %s"
        with self.temporary_database_connection() as conn, conn.cursor() as cur:
            cur.execute(sql_text, (token_hash,))

    # ---------------------------
    # Device token helpers
    # ---------------------------
    def create_device_tokens_table(self) -> None:
        """Create the device_tokens table and indexes if they don't exist."""
        sql_text = """
        CREATE TABLE IF NOT EXISTS device_tokens (
            id SERIAL PRIMARY KEY,
            device_token VARCHAR(255) NOT NULL UNIQUE,
            user_id TEXT NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
        CREATE INDEX IF NOT EXISTS idx_device_token ON device_tokens(device_token);
        """
        with self.temporary_database_connection() as conn, conn.cursor() as cur:
            cur.execute(sql_text)

    def upsert_device_token(self, device_token: str, user_id: str) -> None:
        """Insert a device token or update its user_id/timestamp if it already exists."""
        sql_text = """
        INSERT INTO device_tokens (device_token, user_id)
        VALUES (%s, %s)
        ON CONFLICT (device_token)
        DO UPDATE SET user_id = EXCLUDED.user_id, created_at = CURRENT_TIMESTAMP;
        """
        with self.temporary_database_connection() as conn, conn.cursor() as cur:
            cur.execute(sql_text, (device_token, user_id))

    def get_all_device_tokens(self) -> List[str]:
        """Return a list of all stored device token strings."""
        sql_text = "SELECT device_token FROM device_tokens;"
        with self.temporary_database_connection() as conn, conn.cursor() as cur:
            cur.execute(sql_text)
            return [row[0] for row in cur.fetchall()]

# db = DB()

# # Create or ensure a participant exists
# participant_id = db.create_participant_if_missing("P0001")

# # # Insert some dummy hr data
# # db.insert_hr("P0001", [
# #     {"ts": "2025-10-04T12:00:00Z", "url": "url"},
# #     {"ts": "2025-10-04T12:00:01Z",  "url": "url"},
# # ])

# # Refresh presence materialized views
# db.refresh_summary_cache()

# print()

# # Get dashboard rows
# # print(db.get_dashboard())