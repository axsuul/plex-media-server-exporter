# The first stage is dedicated to building the application
FROM ruby:3.2.2-alpine as BUILD

ENV PORT=9594 \
    USER=app \
    GROUP=appgroup \
    ROOT=/srv

WORKDIR $ROOT

# Updating system packages and installing dependencies
RUN apk update && apk upgrade && \
    apk add --update --no-cache --virtual .build-deps \
    build-base \
    libffi-dev \
    ruby-dev

# Copy the Gemfile and Gemfile.lock
COPY Gemfile Gemfile.lock $ROOT/

# Run the specific version of bundle to install all the necessary libraries
RUN gem install bundler && \
    bundle install && \
    apk del .build-deps && \
    rm -rf /usr/local/bundle/cache/*.gem && \
    find /usr/local/bundle/gems/ -name "*.c" -delete && \
    find /usr/local/bundle/gems/ -name "*.o" -delete

COPY . $ROOT/

# The second stage is responsible for preparing the runtime
FROM ruby:3.2.2-alpine as RUNTIME

# Copy over files from the BUILD step
COPY --from=BUILD $ROOT $ROOT

# Set environmental variables
ENV PORT=9594 \
    USER=app \
    GROUP=appgroup \
    ROOT=/srv

WORKDIR $ROOT

RUN addgroup -S $GROUP && \
    adduser -S $USER -G $GROUP && \
    chown -R $USER:$GROUP $ROOT && \
    chmod 755 config.ru

USER $USER:$GROUP

CMD bundle exec puma -b tcp://0.0.0.0:$PORT