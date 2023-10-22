CREATE TABLE auth_user (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email VARCHAR (255) NOT NULL,
    password VARCHAR (255) NOT NULL
);

--Add Username and Password for Admin User
-- INSERT INTO auth_user (email, password) VALUES ('thomasfookins007helby@gmail.com', '123456');
INSERT INTO auth_user (email, password) VALUES ('iambatmanthegoat@gmail.com', '123456');