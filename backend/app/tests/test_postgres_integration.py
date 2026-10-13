"""SQL that mocks can't check, run against a real Postgres.

Skipped unless TEST_DATABASE_URL points at a server we may create and drop a
scratch database on, e.g.
    TEST_DATABASE_URL=postgresql://postgres@localhost/postgres python -m pytest tests/
"""
import hashlib
import os
import uuid

import psycopg2
import pytest

from database.database import DB
from database import database_runner as schema
from migrate_surveys_to_participant_hash import move_surveys

SERVER_URL = os.getenv("TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(not SERVER_URL, reason="TEST_DATABASE_URL not set")


def _with_dbname(url: str, name: str) -> str:
    # Swap the database name in a postgresql://.../<db>?... URL
    head, _, tail = url.partition("?")
    head = head.rsplit("/", 1)[0] + "/" + name
    return head + ("?" + tail if tail else "")


@pytest.fixture
def db():
    name = "it_" + uuid.uuid4().hex[:12]
    admin = psycopg2.connect(SERVER_URL)
    admin.autocommit = True
    admin.cursor().execute(f"CREATE DATABASE {name}")
    database = DB(_with_dbname(SERVER_URL, name))
    database.create_users_table()
    database.create_account_participants_table()
    yield database
    database.close_all_pool_connections()
    admin.cursor().execute(f"DROP DATABASE {name}")
    admin.close()


def _sql(db, text, params=None):
    with db.temporary_database_connection() as conn, conn.cursor() as cur:
        cur.execute(text, params)
        return cur.fetchall() if cur.description else None


def _add_user(db, apple_id):
    return _sql(db, "INSERT INTO users (apple_id) VALUES (%s) RETURNING id", (apple_id,))[0][0]


class TestBackfillAccountParticipants:
    def test_links_every_account_to_the_login_hash(self, db):
        ids = {_add_user(db, a): a for a in ("001234.abc.0001", "009876.def.0002")}

        assert db.backfill_account_participants() == 2

        for user_id, apple_id in ids.items():
            # Must equal what /auth/login stores: sha256(apple_sub.encode())
            assert db.get_participant_id_for_user(user_id) == hashlib.sha256(apple_id.encode()).hexdigest()

    def test_second_run_adds_nothing(self, db):
        _add_user(db, "001234.abc.0001")
        db.backfill_account_participants()
        assert db.backfill_account_participants() == 0

    def test_never_overwrites_a_login_link(self, db):
        user_id = _add_user(db, "001234.abc.0001")
        db.link_account_participant(user_id, "linked-at-login", 1.0)

        db.backfill_account_participants()

        assert db.get_participant_id_for_user(user_id) == "linked-at-login"


# ---------------------------------------------------------------------------
# One-time survey move (migrate_surveys_to_participant_hash.py)
# ---------------------------------------------------------------------------

def _pid_hash(apple_id):
    return hashlib.sha256(apple_id.encode()).hexdigest()


@pytest.fixture
def survey_db(db):
    for ddl in (schema.SQL_01_BASE, schema.SQL_03B_SURVEY_TABLE,
                schema.SQL_03_PRESENCE_MVS, schema.SQL_03A_PRESENCE_MV_UNIQUES):
        _sql(db, ddl)
    return db


def _participant(db, external_id):
    return _sql(db, "INSERT INTO participants (external_id) VALUES (%s) RETURNING id", (external_id,))[0][0]


def _survey(db, participant_id, day):
    _sql(db, "INSERT INTO daily_survey (participant_id, survey_date, object_url, payload) "
             "VALUES (%s, %s, 'surveys/x.json', '{}')", (participant_id, day))


def _surveys_of(db, external_id):
    return [r[0].isoformat() for r in _sql(db,
        "SELECT d.survey_date FROM daily_survey d JOIN participants p ON p.id = d.participant_id "
        "WHERE p.external_id = %s ORDER BY 1", (external_id,))]


def _run(db, apply=True):
    conn = psycopg2.connect(db.database_url_connection_string)
    try:
        report = move_surveys(conn)
        conn.commit() if apply else conn.rollback()
        return report
    finally:
        conn.close()


class TestMoveSurveysToParticipantHash:
    def test_moves_account_number_surveys_to_existing_hash_participant(self, survey_db):
        db = survey_db
        uid = _add_user(db, "apple.two")
        src = _participant(db, str(uid))
        _participant(db, _pid_hash("apple.two"))          # already has sensor data
        _survey(db, src, "2026-09-01")
        _survey(db, src, "2026-09-02")

        report = _run(db)

        assert report == [{"user_id": uid, "target": _pid_hash("apple.two"),
                           "target_created": False, "moved": 2, "left_same_day": 0}]
        assert _surveys_of(db, _pid_hash("apple.two")) == ["2026-09-01", "2026-09-02"]
        assert _surveys_of(db, str(uid)) == []
        # The emptied participant row is kept (deleting would cascade)
        assert _sql(db, "SELECT count(*) FROM participants WHERE external_id = %s", (str(uid),))[0][0] == 1

    def test_creates_hash_participant_when_missing(self, survey_db):
        db = survey_db
        uid = _add_user(db, "apple.one")
        _survey(db, _participant(db, str(uid)), "2026-09-01")

        report = _run(db)

        assert report[0]["target_created"] is True
        assert _surveys_of(db, _pid_hash("apple.one")) == ["2026-09-01"]

    def test_same_day_collision_is_left_in_place_and_reported(self, survey_db):
        db = survey_db
        uid = _add_user(db, "apple.two")
        src = _participant(db, str(uid))
        dst = _participant(db, _pid_hash("apple.two"))
        _survey(db, src, "2026-09-01")
        _survey(db, src, "2026-09-02")
        _survey(db, dst, "2026-09-02")                    # filed under the hash after deploy

        report = _run(db)

        assert (report[0]["moved"], report[0]["left_same_day"]) == (1, 1)
        assert _surveys_of(db, str(uid)) == ["2026-09-02"]

    def test_dry_run_changes_nothing(self, survey_db):
        db = survey_db
        uid = _add_user(db, "apple.one")
        _survey(db, _participant(db, str(uid)), "2026-09-01")

        report = _run(db, apply=False)

        assert report[0]["moved"] == 1                    # counts are real...
        assert _surveys_of(db, str(uid)) == ["2026-09-01"]  # ...but rolled back
        assert _sql(db, "SELECT count(*) FROM participants WHERE external_id = %s",
                    (_pid_hash("apple.one"),))[0][0] == 0

    def test_second_run_is_a_no_op(self, survey_db):
        db = survey_db
        uid = _add_user(db, "apple.one")
        _survey(db, _participant(db, str(uid)), "2026-09-01")
        _run(db)
        assert _run(db) == []

    def test_non_account_participants_untouched(self, survey_db):
        db = survey_db
        _add_user(db, "apple.one")                        # user id 1, but no "1" participant
        for ext in ("unknown", "P0001", "samir"):
            _survey(db, _participant(db, ext), "2026-09-01")

        assert _run(db) == []
        for ext in ("unknown", "P0001", "samir"):
            assert _surveys_of(db, ext) == ["2026-09-01"]

    def test_refreshes_survey_presence_view(self, survey_db):
        db = survey_db
        uid = _add_user(db, "apple.one")
        _survey(db, _participant(db, str(uid)), "2026-09-01")

        _run(db)

        rows = _sql(db, "SELECT p.external_id, m.forms FROM mv_survey_daily_presence m "
                        "JOIN participants p ON p.id = m.participant_id")
        assert rows == [(_pid_hash("apple.one"), 1)]
