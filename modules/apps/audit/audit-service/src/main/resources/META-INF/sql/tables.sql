create table AuditEvent (
	auditEventId LONG not null primary key,
	companyId LONG,
	userId LONG,
	userName VARCHAR(75) null,
	createDate DATE null,
	eventType VARCHAR(75) null,
	className VARCHAR(75) null,
	classPK VARCHAR(75) null,
	message VARCHAR(75) null,
	clientHost VARCHAR(75) null,
	clientIP VARCHAR(75) null,
	serverName VARCHAR(75) null,
	serverPort INTEGER,
	sessionID VARCHAR(75) null,
	additionalInfo VARCHAR(75) null
);