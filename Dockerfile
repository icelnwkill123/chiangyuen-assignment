# Base Ruby image
FROM ruby:3.2-alpine

# Install build dependencies for sqlite3 gem
RUN apk add --no-cache build-base sqlite-dev tzdata

# Set working directory
WORKDIR /app

# Install webrick and sqlite3 gems
RUN gem install webrick sqlite3 --no-document

# Copy application files
COPY . .

# Ensure upload directory exists and has correct permissions
RUN mkdir -p /app/uploads /app/db && chmod -R 777 /app/uploads /app/db

# Expose port (Render automatically injects PORT environment variable)
ENV PORT=8080
ENV TEACHER_PASSWORD=021047

EXPOSE 8080

# Start server
CMD ["ruby", "server.rb"]
