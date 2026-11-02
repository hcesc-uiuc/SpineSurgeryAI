# Presigned upload flow (accel / sensorkit / sqlite)

Each step is a separate HTTP request with its own reply. Only step 3 returning
`"status":"completed"` means the backend recorded the upload. The app (and the
harness, which vendors the same code) currently decides pass/fail from step 2
only and ignores the step 3 reply.

```mermaid
flowchart TD
    A([Phone: file ready in to-be-processed/]) --> B

    subgraph S1 [Step 1 - Presign]
        B[Phone to Backend<br/>POST /uploads/presign<br/>filename, kind, participantId] --> C{Backend}
        C -->|kind not allowed / DB error| C1[Reply: 400 or 500]
        C -->|ok| C2[Saves pending row in DB<br/>status = pending<br/>Reply: 201 + upload_id + S3 link]
    end

    C1 --> FAIL1([App: fail, file stays, retry later])
    C2 --> D

    subgraph S2 [Step 2 - Upload file]
        D[Phone to S3<br/>PUT file to the link] --> E{S3}
        E -->|bad/expired key or link| E1[Reply: 403]
        E -->|stored| E2[Reply: 200]
    end

    E1 --> F
    E2 --> F

    subgraph S3 [Step 3 - Complete]
        F[Phone to Backend<br/>POST /uploads/complete<br/>upload_id, success] --> G{Backend}
        G -->|phone says failed| G1[Deletes S3 object<br/>marks row failed<br/>Reply: 200 status=failed]
        G -->|phone says ok| H{Is the file really in S3?}
        H -->|no| H1[Marks row failed<br/>Reply: 200 status=failed<br/>error: object not found]
        H -->|yes| H2[Marks row completed<br/>accel: adds row for dashboard + checker<br/>Reply: 200 status=completed]
        G -->|unknown upload_id| G2[Reply: 404]
        G -->|crash| G3[Reply: 500]
    end

    G1 --> R
    H1 --> R
    H2 --> R
    G2 --> R
    G3 --> R

    R[App prints step 3 reply<br/>but IGNORES it] --> DEC{App decides using<br/>step 2 result only}
    DEC -->|step 2 was 200| OK([Move file to processed/<br/>never retried])
    DEC -->|step 2 not 200| FAIL2([Fail, file stays, retry later])

    classDef bad fill:#fde2e2,stroke:#c0392b,color:#000
    classDef good fill:#e2f5e6,stroke:#27ae60,color:#000
    classDef warn fill:#fff4d6,stroke:#e0a800,color:#000
    class C1,E1,G1,H1,G2,G3,FAIL1,FAIL2 bad
    class C2,E2,H2 good
    class R,DEC,OK warn
```

Location (`locations_`) and HealthKit (`healthkit_`) files skip this flow: they
are sent in one multipart `POST /api/noauth/uploadfile`, which stores the file
and records the DB row in the same request.
