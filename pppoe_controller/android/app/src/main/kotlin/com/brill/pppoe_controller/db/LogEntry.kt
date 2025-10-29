package com.brill.pppoe_controller.db

import androidx.room.Entity
import androidx.room.PrimaryKey

@Entity(tableName = "log_history")
data class LogEntry(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val timestamp: Long, // When the attempt started
    var note: String? = null,
    val logContent: String,
    var status: String // e.g., "Success", "Failure", "Timeout", "Unknown"
)