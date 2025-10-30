package com.brill.pppoe_controller.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query
import androidx.room.Update

@Dao
interface LogEntryDao {
    @Insert
    suspend fun insert(logEntry: LogEntry): Long // Use suspend for coroutines

    @Query("SELECT id, timestamp, note, status FROM log_history ORDER BY timestamp DESC") // Select only needed fields for list view
    suspend fun getAllSummaries(): List<LogSummary> // Use a projection for efficiency

    @Query("SELECT * FROM log_history WHERE id = :id")
    suspend fun getById(id: Long): LogEntry?

    @Update
    suspend fun update(logEntry: LogEntry)

    @Query("DELETE FROM log_history WHERE id = :id")
    suspend fun deleteById(id: Long): Int
}

// Define the projection data class for the list view
data class LogSummary(
    val id: Long,
    val timestamp: Long,
    val note: String?,
    val status: String
)