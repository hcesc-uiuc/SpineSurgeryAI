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
