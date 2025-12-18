"""
heatmap.py — generates heatmap locally 

TODO: add more description
"""

import pandas as pd
import altair as alt
import numpy as np
from typing import Optional

from database.database import DB


def generate_participant_heatmap(db: DB, external_id: str) -> Optional[str]:
    """Generate and return heatmap HTML for a single participant."""
    
    df_health = pd.DataFrame(db.get_table("ingestion_health"))
    df_parts = pd.DataFrame(db.get_table("participants"))
    
    if df_health.empty or df_parts.empty:
        return None
    
    # Add readable participant external ID
    df_health = df_health.merge(
        df_parts[["id", "external_id"]],
        left_on="participant_id",
        right_on="id",
        how="left"
    )
    
    # Filter to just this participant
    df_health = df_health[df_health["external_id"] == external_id]
    
    if df_health.empty:
        return None
    
    # Normalize timestamps and extract day + 15-minute slot index
    df_health["window_start"] = pd.to_datetime(df_health["window_start"])
    df_health["day"] = df_health["window_start"].dt.date
    df_health["slot_index"] = (
        df_health["window_start"].dt.hour * 4 +
        df_health["window_start"].dt.minute // 15
    ).astype(int)  # 0–95
    
    # Threshold for marking slot as "usable"
    GOOD_THRESHOLD = 80  # % expected
    df_health["good_window"] = df_health["pct_expected"] >= GOOD_THRESHOLD
    
    # build 96 slot grid
    participants = df_health["external_id"].unique()
    modalities = df_health["modality"].unique()
    days = df_health["day"].unique()
    slots = np.arange(96, dtype=int)
    
    base_grid = (
        pd.MultiIndex.from_product(
            [participants, modalities, days, slots],
            names=["external_id", "modality", "day", "slot_index"]
        )
        .to_frame(index=False)
    )
    
    # Actual ingestion windows aggregated to slots
    slot_data = (
        df_health
        .groupby(["external_id", "modality", "day", "slot_index"], as_index=False)
        .agg(
            good=("good_window", "max"),      # was there any good window in this slot?
            pct=("pct_expected", "mean")      # mean pct_expected for tooltip
        )
    )
    
    grid = base_grid.merge(
        slot_data,
        how="left",
        on=["external_id", "modality", "day", "slot_index"]
    )
    
    grid["good"] = grid["good"].fillna(False)
    grid["pct"] = grid["pct"].fillna(0.0)
    
    # Convert day to datetime for Altair
    grid["day"] = pd.to_datetime(grid["day"])
    
    # Chart
    base_chart = (
        alt.Chart(grid)
        .mark_rect()
        .encode(
            x=alt.X(
                "slot_index:O",
                title="15-min Slots (0–95)",
                axis=alt.Axis(
                    labelAngle=0,
                    # Only label every 8th slot (~2 hours) to avoid clutter
                    labelExpr="datum.value % 8 == 0 ? datum.value : ''"
                )
            ),
            y=alt.Y("external_id:N", title="Participant"),
            color=alt.Color(
                "good:N",
                title="Good window",
                scale=alt.Scale(
                    domain=[False, True],
                    range=["#440154", "#FDE725"]  # purple = missing, yellow = good
                )
            ),
            tooltip=[
                "external_id",
                "modality",
                alt.Tooltip("day:T", title="Date"),
                alt.Tooltip("slot_index:Q", title="Slot (0–95)"),
                alt.Tooltip("good:N", title="Usable?"),
                alt.Tooltip("pct:Q", title="% expected", format=".1f")
            ]
        )
    ).properties(
        width=600,
        height=60
    )
    
    # ------------------------------
    # Facet by modality and day
    # ------------------------------
    heatmap = base_chart.facet(
        row=alt.Row("modality:N", title="Modality"),
        column=alt.Column("day:T", title="Day")
    ).properties(
        title=f"Valid Data for: {external_id}"
    )
    html = heatmap.to_html()
    stats = get_participant_compliance_stats(db, external_id)

    if stats:
        stats_html = f"""
        <div style="font-family: sans-serif; padding: 20px; background: #f5f5f5; margin-bottom: 20px;">
            <h2>Compliance Stats - {external_id} (Last 7 Days)</h2>
            <p><strong>Overall:</strong> {stats['percentage']}% ({stats['total_good_slots']} / {stats['total_possible_slots']} slots)</p>
            <ul>
        """
        for mod, data in stats['by_modality'].items():
            stats_html += f"<li><strong>{mod}:</strong> {data['percentage']}% ({data['good_slots']} / {data['total_slots']} slots)</li>"
        stats_html += "</ul></div>"
        
        html = html.replace("<body>", f"<body>{stats_html}")
    
    return html


# check logic!!
def get_participant_compliance_stats(db: DB, external_id: str) -> Optional[dict]:
    """Calculate upload compliance stats for last 7 days."""
    
    df_health = pd.DataFrame(db.get_table("ingestion_health"))
    df_parts = pd.DataFrame(db.get_table("participants"))
    
    if df_health.empty or df_parts.empty:
        return None
    
    df_health = df_health.merge(
        df_parts[["id", "external_id"]],
        left_on="participant_id",
        right_on="id",
        how="left"
    )
    
    df_health = df_health[df_health["external_id"] == external_id]
    
    if df_health.empty:
        return None
    
    df_health["window_start"] = pd.to_datetime(df_health["window_start"])
    df_health["day"] = df_health["window_start"].dt.date
    df_health["slot_index"] = (
        df_health["window_start"].dt.hour * 4 +
        df_health["window_start"].dt.minute // 15
    ).astype(int)
    
    # Filter to last 7 days
    from datetime import datetime, timedelta
    today = datetime.now().date()
    week_ago = today - timedelta(days=6)
    df_week = df_health[df_health["day"] >= week_ago]
    
    if df_week.empty:
        return {
            "external_id": external_id,
            "total_possible_slots": 7 * 96,
            "total_uploads": 0,
            "percentage": 0.0,
            "by_modality": {}
        }
    
    GOOD_THRESHOLD = 80
    df_week["good_window"] = df_week["pct_expected"] >= GOOD_THRESHOLD
    
    modalities = df_week["modality"].unique()
    
    # Total possible = 7 days * 96 slots per day * number of modalities
    total_possible_per_modality = 7 * 96
    total_possible = total_possible_per_modality * len(modalities)
    
    # Count unique (day, slot, modality) combos with good data
    good_slots = df_week[df_week["good_window"]].groupby(
        ["modality", "day", "slot_index"]
    ).size().reset_index(name="count")
    
    total_good = len(good_slots)
    overall_pct = (total_good / total_possible * 100) if total_possible > 0 else 0
    
    # Per modality breakdown
    by_modality = {}
    for mod in modalities:
        mod_good = len(good_slots[good_slots["modality"] == mod])
        mod_pct = (mod_good / total_possible_per_modality * 100)
        by_modality[mod] = {
            "good_slots": mod_good,
            "total_slots": total_possible_per_modality,
            "percentage": round(mod_pct, 1)
        }
    
    return {
        "external_id": external_id,
        "total_possible_slots": total_possible,
        "total_good_slots": total_good,
        "percentage": round(overall_pct, 1),
        "by_modality": by_modality
    }