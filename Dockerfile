FROM ruby:3.0.5-alpine


MAINTAINER James Hu <hello@james.hu>

ENV PORT 9594
ENV ROOT /srv

RUN apk add --update --no-cache --virtual ffi-dependencies build-base libffi-dev ruby-dev


CMD bundle exec puma --port $PORT

WORKDIR $ROOT

COPY Gemfile Gemfile.lock .

RUN bundle install

COPY . $ROOT

RUN chmod +x config.ru && \
	apk del --purge ffi-dependencies build-base libffi-dev ruby-dev
