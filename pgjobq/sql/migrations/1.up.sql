CREATE SCHEMA pgjobq;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

create table pgjobq.migrations (
    current_revision smallint not null
);

INSERT INTO pgjobq.migrations VALUES (0);

create table pgjobq.queues (
    id serial primary key,
    name text not null,
    UNIQUE(name),
    -- default values for inserted messages
    ack_deadline interval not null,
    max_delivery_attempts integer not null,
    retention_period interval not null,
    -- statistics
    current_message_count integer not null DEFAULT 0, -- current number of messages in the queue
    undelivered_message_count integer not null DEFAULT 0 -- number of messages that have never been delivered
);

create table pgjobq.messages (
    queue_id serial references pgjobq.queues on delete cascade not null,
    id uuid, -- generated by app so it can start waiting for results before publishing
    PRIMARY KEY(queue_id, id),
    expires_at timestamp not null,
    delivery_attempts integer not null,
    available_at timestamp not null,
    body bytea not null
) PARTITION BY LIST(queue_id);

-- Index for ackinc/nacknig messages within a partition
CREATE INDEX "pgjobq.messages_id_idx" ON pgjobq.messages(id);

-- Indexes for looking for expired messages and available messages
CREATE INDEX "pgjobq.messages_available_idx"
ON pgjobq.messages(available_at);

CREATE INDEX "pgjobq.messages_expiration_idx"
ON pgjobq.messages(delivery_attempts, expires_at);

CREATE FUNCTION pgjobq.create_queue(
    queue_name varchar(32),
    ack_deadline interval,
    max_delivery_attempts integer,
    retention_period interval
)
    RETURNS boolean
    LANGUAGE plpgsql AS
$$
DECLARE
    found_queue_id integer;
    messages_partition_table_name text;
BEGIN
    WITH new_queue AS (
        INSERT INTO pgjobq.queues(name, ack_deadline, max_delivery_attempts, retention_period)
        VALUES (queue_name, ack_deadline, max_delivery_attempts, retention_period)
        ON CONFLICT DO NOTHING
        RETURNING id AS queue_id
    )
    SELECT queue_id
    INTO found_queue_id
    FROM new_queue;
    IF found THEN
        messages_partition_table_name := 'pgjobq.messages_' || found_queue_id::text;
        EXECUTE format(
            'CREATE TABLE %I PARTITION OF pgjobq.messages FOR VALUES IN (%L);',
            messages_partition_table_name,
            found_queue_id
        );
    END IF;
    RETURN found;
END
$$;

CREATE FUNCTION pgjobq.delete_queue(
    queue_name varchar(32)
)
    RETURNS boolean
    LANGUAGE plpgsql AS
$$
DECLARE
    found_queue_id integer;
    messages_partition_table_name text;
BEGIN
    WITH deleted_queue AS (
        DELETE
        FROM pgjobq.queues
        WHERE name = queue_name
        RETURNING id
    )
    SELECT id
    INTO found_queue_id
    FROM deleted_queue;
    IF found THEN
        messages_partition_table_name :=  'pgjobq.messages_' || found_queue_id::text;
        EXECUTE format(
            'DROP TABLE %I CASCADE;',
            messages_partition_table_name
        );
    END IF;
    RETURN found;
END
$$;

CREATE FUNCTION pgjobq.cleanup_dead_messages()
    RETURNS VOID
    LANGUAGE sql AS
$$
    DELETE
    FROM pgjobq.messages
    USING pgjobq.queues
    WHERE (
        pgjobq.queues.id = pgjobq.messages.queue_id
        AND
        available_at < now()
        AND (
            expires_at < now()
            OR
            delivery_attempts >= max_delivery_attempts
        )
    );
$$;
