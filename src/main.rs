use imessage_database::{
    error::table::TableError,
    tables::{
        messages::Message,
        table::{get_connection, Table},
        handle::Handle,
    },
    util::dirs::default_db_path,
};
use chrono::{DateTime, Utc, Duration, TimeZone, NaiveDate};
use std::fs::File;
use std::io::Write;
use serde_json::json;
use std::error::Error;
use std::fmt;
use clap::Parser;

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    /// Output file path
    #[arg(short, long)]
    output_file: String,

    /// Start date in YYYY-MM-DD format
    #[arg(short, long)]
    start_date: Option<String>,

    /// End date in YYYY-MM-DD format
    #[arg(short, long)]
    end_date: Option<String>,

    /// Only include messages sent by the user
    #[arg(short = 'm', long)]
    only_from_me: bool,
}

#[derive(Debug)]
enum AppError {
    Table(TableError),
    Io(std::io::Error),
    Args(String),
}

impl fmt::Display for AppError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            AppError::Table(e) => write!(f, "Database error: {}", e),
            AppError::Io(e) => write!(f, "IO error: {}", e),
            AppError::Args(e) => write!(f, "Argument error: {}", e),
        }
    }
}

impl Error for AppError {}

impl From<TableError> for AppError {
    fn from(err: TableError) -> Self {
        AppError::Table(err)
    }
}

impl From<std::io::Error> for AppError {
    fn from(err: std::io::Error) -> Self {
        AppError::Io(err)
    }
}

#[derive(Debug)]
struct MessageData {
    id: i64,
    date: DateTime<Utc>,
    text: Option<String>,
    from_me: bool,
    from: Option<String>,
    to: Option<String>,
}

fn parse_date(date_str: &str) -> Result<DateTime<Utc>, AppError> {
    NaiveDate::parse_from_str(date_str, "%Y-%m-%d")
        .map_err(|e| AppError::Args(format!("Invalid date format: {}. Expected YYYY-MM-DD", e)))
        .map(|date| DateTime::from_naive_utc_and_offset(date.and_hms_opt(0, 0, 0).unwrap(), Utc))
}

fn main() -> Result<(), AppError> {
    let args = Args::parse();
    let db_path = default_db_path();
    let db = get_connection(&db_path)?;

    let imessage_epoch = Utc.with_ymd_and_hms(2001, 1, 1, 0, 0, 0).unwrap();

    // Parse start and end dates
    let start_date = args.start_date
        .map(|d| parse_date(&d))
        .transpose()?
        .unwrap_or_else(|| Utc::now() - Duration::days(7));

    let end_date = args.end_date
        .map(|d| parse_date(&d))
        .transpose()?
        .unwrap_or_else(|| Utc::now());

    let start_date_ns = (start_date - imessage_epoch).num_nanoseconds().unwrap_or(0);
    let end_date_ns = (end_date - imessage_epoch).num_nanoseconds().unwrap_or(0);

    // Build handle map at the start
    let mut handle_map = std::collections::HashMap::new();
    let mut handle_stmt = Handle::get(&db)?;
    let handles_iter = handle_stmt
        .query_map([], |row| Ok(Handle::from_row(row)))
        .map_err(|e| TableError::Messages(e))?;

    for handle_result in handles_iter {
        if let Ok(handle) = handle_result {
            if let Ok(handle) = handle {
                handle_map.insert(handle.rowid, handle.id);
            }
        }
    }

    let mut statement = Message::get(&db)?;
    let messages_iter = statement
        .query_map([], |row| Ok(Message::from_row(row)))
        .map_err(|e| TableError::Messages(e))?;

    let mut messages = Vec::new();

    for message_result in messages_iter {
        let mut msg = Message::extract(message_result)?;
        if let Err(_) = msg.generate_text(&db) {
            continue;
        }

        let message_date = imessage_epoch + Duration::nanoseconds(msg.date);

        if msg.date >= start_date_ns && msg.date <= end_date_ns && (!args.only_from_me || msg.is_from_me) {
            // Get the actual phone numbers using the handle map
            let from_number = if msg.is_from_me {
                msg.destination_caller_id.clone()
            } else {
                msg.handle_id.and_then(|id| handle_map.get(&id).cloned())
            };

            let to_number = if msg.is_from_me {
                msg.handle_id.and_then(|id| handle_map.get(&id).cloned())
            } else {
                msg.destination_caller_id.clone()
            };

            let message_data = MessageData {
                id: msg.rowid as i64,
                date: message_date,
                text: msg.text,
                from_me: msg.is_from_me,
                from: from_number,
                to: to_number,
            };

            let message_json = json!({
                "id": message_data.id,
                "date": message_data.date.timestamp(),
                "text": message_data.text,
                "from": message_data.from,
                "to": message_data.to,
                "from_me": message_data.from_me
            });

            messages.push(message_json);
        }
    }

    let json_output = json!(messages);
    let mut file = File::create(&args.output_file)?;
    file.write_all(json_output.to_string().as_bytes())?;

    Ok(())
}
