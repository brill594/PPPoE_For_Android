package com.brill.pppoe_controller.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query

@Dao
interface LogEntryDao {
    @Insert
    suspend fun insert(logEntry: LogEntry): Long // Use suspend for coroutines

    @Query("SELECT id, timestamp, note, status FROM log_history ORDER BY timestamp DESC") // Select only needed fields for list view
    suspend fun getAllSummaries(): List<LogSummary> // Use a projection for efficiency

    @Query("SELECT * FROM log_history WHERE id = :id")
    suspend fun getById(id: Long): LogEntry?

    @Query("UPDATE log_history SET status = :status WHERE id = :id")
    suspend fun updateStatus(id: Long, status: String): Int

    @Query("UPDATE log_history SET note = :note WHERE id = :id")
    suspend fun updateNote(id: Long, note: String?): Int

    @Query("UPDATE log_history SET logContent = logContent || :text WHERE id = :id")
    suspend fun appendLog(id: Long, text: String): Int

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